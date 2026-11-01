"""Barra de status do Claude Code para as sessoes fora do CE.

Uma linha: plano, nome da sessao, modelo, pasta, contexto usado e as janelas
de cota de 5 h e de 7 dias, com amarelo a partir de 70% e vermelho a partir
de 90%. O plano e a cor chegam por argumento, gravados no settings.json de
cada diretorio de estado por scripts\\set-statusline.ps1 a partir do mapa de
perfis. Repositorio com statusLine propria no projeto continua com a dele.

Em Python, nao em PowerShell, por custo: a CLI roda este comando a cada
atualizacao da conversa, em cada sessao aberta. Medido em 01/11/2026 numa
maquina com cinco sessoes: pwsh -NoProfile ~280 ms por chamada, python ~47 ms.

Somente leitura: le o JSON da entrada padrao e escreve uma linha. Campo
ausente ou estranho vira "?" ou some; a barra nunca quebra a sessao.

Uso:
    python -I statusline.py --plano "DEV BLINDADO" --cor magenta < evento.json
    python -I statusline.py --teste
"""

import argparse
import json
import os
import sys
import time

CORES = {
    "black": "30", "red": "31", "green": "32", "yellow": "33",
    "blue": "34", "magenta": "35", "cyan": "36", "white": "37",
}
AMARELO, VERMELHO = "33", "31"


def _pct(valor):
    if isinstance(valor, bool):
        return None
    try:
        p = float(valor)
    except (TypeError, ValueError):
        return None
    if p != p:  # NaN
        return None
    return max(0.0, min(100.0, p))


def _pintar(texto, codigo, cores):
    return "\x1b[%sm%s\x1b[0m" % (codigo, texto) if cores and codigo else texto


def _nivel(p):
    if p is None:
        return None
    if p >= 90:
        return VERMELHO
    if p >= 70:
        return AMARELO
    return None


def _janela(rotulo, limites, chave, agora, cores):
    jan = limites.get(chave) if isinstance(limites, dict) else None
    if not isinstance(jan, dict):
        return None
    p = _pct(jan.get("used_percentage"))
    if p is None:
        return None
    texto = "%s %.0f%%" % (rotulo, p)
    try:
        zera = float(jan.get("resets_at"))
    except (TypeError, ValueError):
        zera = None
    if zera is not None and zera > agora:
        formato = "%H:%M" if chave == "five_hour" else "%d/%m %Hh"
        texto += " ate " + time.strftime(formato, time.localtime(zera))
    return _pintar(texto, _nivel(p), cores)


def montar(dados, plano="", cor="", cores=True, agora=None):
    agora = time.time() if agora is None else agora
    dados = dados if isinstance(dados, dict) else {}
    partes = []
    if plano:
        partes.append(_pintar(plano, CORES.get(cor.lower(), ""), cores))
    nome = dados.get("session_name")
    if isinstance(nome, str) and nome.strip():
        partes.append(nome.strip()[:40])
    modelo = dados.get("model") if isinstance(dados.get("model"), dict) else {}
    partes.append(str(modelo.get("display_name") or modelo.get("id") or "?"))
    area = dados.get("workspace") if isinstance(dados.get("workspace"), dict) else {}
    pasta = area.get("current_dir") or dados.get("cwd")
    if isinstance(pasta, str) and pasta.strip():
        partes.append(os.path.basename(pasta.rstrip("\\/")) or pasta)
    ctx = dados.get("context_window") if isinstance(dados.get("context_window"), dict) else {}
    p = _pct(ctx.get("used_percentage"))
    partes.append(_pintar("ctx %.0f%%" % p, _nivel(p), cores) if p is not None else "ctx ?")
    limites = dados.get("rate_limits")
    for rotulo, chave in (("5h", "five_hour"), ("7d", "seven_day")):
        trecho = _janela(rotulo, limites, chave, agora, cores)
        if trecho:
            partes.append(trecho)
    return " \u00b7 ".join(partes)


def _teste():
    agora = 1_800_000_000.0
    casos = [
        (montar({}, cores=False, agora=agora), "? \u00b7 ctx ?"),
        (montar({"model": {"display_name": "Opus"}, "workspace": {"current_dir": "C:\\Projetos\\Farol"},
                 "context_window": {"used_percentage": 12.4}}, "DEV", "magenta", cores=False, agora=agora),
         "DEV \u00b7 Opus \u00b7 Farol \u00b7 ctx 12%"),
        (montar({"model": {"id": "x"}, "context_window": {"used_percentage": "abc"},
                 "rate_limits": {"five_hour": {"used_percentage": 95}, "seven_day": "lixo"}},
                cores=False, agora=agora),
         "x \u00b7 ctx ? \u00b7 5h 95%"),
        (montar({"session_name": "  limpeza  ", "model": {"display_name": "Opus"},
                 "context_window": {"used_percentage": True}}, cores=False, agora=agora),
         "limpeza \u00b7 Opus \u00b7 ctx ?"),
    ]
    falhas = [(obtido, esperado) for obtido, esperado in casos if obtido != esperado]
    pintado = montar({"context_window": {"used_percentage": 91}}, "DEV", "magenta", agora=agora)
    if "\x1b[35mDEV" not in pintado or "\x1b[31mctx 91%" not in pintado:
        falhas.append((pintado, "cores do plano e do contexto"))
    zera = montar({"rate_limits": {"five_hour": {"used_percentage": 40, "resets_at": agora + 3600}}},
                  cores=False, agora=agora)
    if " ate " not in zera:
        falhas.append((zera, "hora em que a janela zera"))
    for obtido, esperado in falhas:
        print("FALHOU: %r != %r" % (obtido, esperado))
    print("statusline: %d falha(s)" % len(falhas))
    return 1 if falhas else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Barra de status do Claude Code.")
    parser.add_argument("--plano", default="")
    parser.add_argument("--cor", default="")
    parser.add_argument("--teste", action="store_true")
    args = parser.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    if args.teste:
        return _teste()
    try:
        dados = json.loads(sys.stdin.read() or "{}")
    except (ValueError, UnicodeDecodeError):
        dados = {}
    cores = not os.environ.get("NO_COLOR")
    sys.stdout.write(montar(dados, args.plano, args.cor, cores=cores) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
