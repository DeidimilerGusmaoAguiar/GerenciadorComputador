<#
.SYNOPSIS
Roda UM trabalho pesado por vez na maquina inteira, sob teto de CPU e de memoria.

.DESCRIPTION
Runner opt-in para build, restore e suites de teste. Varias sessoes de agentes
rodando trabalho pesado ao mesmo tempo levam o commit acima de 80%; este script
faz fila e limita o que cada trabalho pode consumir.

Fila: a vaga e um mutex nomeado do Windows (Local\GerenciadorComputador-
TrabalhoPesado-<i>, i de 1 a -Vagas). O mutex devolve a vaga sozinho se o dono
morrer: nesse caso o runner a assume com um aviso (AbandonedMutexException). Um
semaforo nao faria isso. Enquanto espera, imprime uma linha a cada ~30 s. Se a
espera passar de -EsperaMaxMinutos, sai com o codigo 124. Como o mutex e
"Local\", a fila vale por sessao de logon do Windows.

Teto: o comando roda dentro de um Job Object com
- teto de memoria do JOB inteiro (JOB_OBJECT_LIMIT_JOB_MEMORY): alocar alem dele
  falha no filho;
- teto de CPU rigido (CPU_RATE_CONTROL HARD_CAP), em porcentagem do total da
  maquina, nao de um nucleo;
- KILL_ON_JOB_CLOSE: ao terminar o runner, por Ctrl+C ou por fechamento da
  janela, toda a arvore do job e encerrada. Isso inclui processos que o filho
  deixou em segundo plano (por exemplo servidores de build); o runner so encerra
  o que esta dentro do proprio job e nunca usa Stop-Process nem taskkill.

Nao existe teto de I/O: SetIoRateControlInformationJobObject nao e suportado
desde o Windows 10 1607, entao este runner nao limita disco nem rede.

Sem corrida: o processo nasce suspenso (CREATE_SUSPENDED), entra no job e so
entao e retomado. Nenhuma instrucao do filho roda fora do teto.

A saida do filho vai direto ao mesmo console (os handles sao herdados). O codigo
de saida do filho e o do runner. Codigos proprios do runner: 124 = espera pela
vaga estourou; 125 = erro do runner (argumento, comando nao encontrado, falha
ao criar o job). Um filho que devolva 124 ou 125 e indistinguivel desses.

Ao fim, imprime uma linha de resumo: duracao, pico de memoria do job e se o job
bateu no teto de memoria. O runner nao altera o host, entao nao tem -Execute;
-WhatIf mostra limites, vaga e comando sem rodar nada.

Teto de memoria e sobre memoria COMPROMETIDA (commit), nao working set. O .NET le
o teto do job e recusa alocar por conta propria perto de 75% dele; nesse caso o
Windows nao notifica e o resumo so aponta que o pico passou de 70%.

Use sempre "--" antes do comando, para que seus argumentos nao sejam lidos como
parametros do runner.

.PARAMETER CpuPorcento
Teto de CPU em porcentagem do total da maquina (1 a 100). Padrao 50.

.PARAMETER MemoriaGB
Teto de memoria comprometida do job, em GB (aceita fracao). Padrao: 40% da RAM
fisica, arredondado a 0,1 GB.

.PARAMETER Vagas
Quantos trabalhos pesados podem rodar ao mesmo tempo na maquina. Padrao 1.

.PARAMETER EsperaMaxMinutos
Quanto esperar por uma vaga antes de desistir com codigo 124. 0 = nao espera.

.PARAMETER NomeVaga
Prefixo dos mutexes. So muda em teste; manter o padrao para que todas as
sessoes disputem as mesmas vagas.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Invoke-TrabalhoPesado.ps1 -- dotnet build

.EXAMPLE
pwsh -NoProfile -File .\scripts\Invoke-TrabalhoPesado.ps1 -CpuPorcento 50 -MemoriaGB 6 -- npm test

.EXAMPLE
pwsh -NoProfile -File .\scripts\Invoke-TrabalhoPesado.ps1 -WhatIf -- dotnet test
#>
# Sem bloco param() de proposito: o pwsh -File recusa "--" em script com
# parametros declarados ("nome de parametro '' e ambiguo"). Por isso os
# parametros sao lidos de $args, e o que vem depois de "--" e o comando.
$CpuPorcento = 50
$MemoriaGB = 0.0
$Vagas = 1
$EsperaMaxMinutos = 60
$NomeVaga = 'Local\GerenciadorComputador-TrabalhoPesado'
$WhatIf = $false

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ExitEspera = 124
$ExitErro = 125

function Write-Runner {
    param([string]$Message)
    Write-Host "[trabalho-pesado] $Message"
}

function Stop-Runner {
    param([string]$Message)
    [Console]::Error.WriteLine("[trabalho-pesado] erro: $Message")
    exit $ExitErro
}

if (-not $IsWindows) { Stop-Runner 'so funciona no Windows (Job Object).' }

function Read-Opcao {
    param([string[]]$Lista, [ref]$Indice, [string]$Nome)
    $Indice.Value++
    if ($Indice.Value -ge $Lista.Count) { Stop-Runner "falta o valor de $Nome." }
    return $Lista[$Indice.Value]
}

function ConvertTo-NumeroFaixa {
    param([string]$Texto, [string]$Nome, [double]$Min, [double]$Max)
    $n = 0.0
    $ok = [double]::TryParse($Texto.Replace(',', '.'), [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    if (-not $ok -or $n -lt $Min -or $n -gt $Max) {
        Stop-Runner "$Nome precisa estar entre $Min e $Max (recebido: $Texto)."
    }
    return $n
}

$tokens = @()
$todos = @($args | ForEach-Object { [string]$_ })
for ($i = 0; $i -lt $todos.Count; $i++) {
    $a = $todos[$i]
    if ($a -eq '--') { $tokens = @($todos | Select-Object -Skip ($i + 1)); break }
    switch -Regex ($a) {
        '^(?i)-CpuPorcento$' { $CpuPorcento = [int](ConvertTo-NumeroFaixa (Read-Opcao $todos ([ref]$i) $a) $a 1 100); continue }
        '^(?i)-MemoriaGB$' { $MemoriaGB = ConvertTo-NumeroFaixa (Read-Opcao $todos ([ref]$i) $a) $a 0.1 4096; continue }
        '^(?i)-Vagas$' { $Vagas = [int](ConvertTo-NumeroFaixa (Read-Opcao $todos ([ref]$i) $a) $a 1 16); continue }
        '^(?i)-EsperaMaxMinutos$' { $EsperaMaxMinutos = [int](ConvertTo-NumeroFaixa (Read-Opcao $todos ([ref]$i) $a) $a 0 1440); continue }
        '^(?i)-NomeVaga$' {
            $NomeVaga = Read-Opcao $todos ([ref]$i) $a
            if ($NomeVaga -notmatch '^Local\\[A-Za-z0-9._-]+$') { Stop-Runner '-NomeVaga deve ser Local\<nome>.' }
            continue
        }
        '^(?i)-WhatIf$' { $WhatIf = $true; continue }
        '^-' { Stop-Runner "opcao desconhecida: $a (use \"--\" antes do comando)." }
        default { $tokens = @($todos | Select-Object -Skip $i); $i = $todos.Count }
    }
}
if ($tokens.Count -eq 0) {
    Stop-Runner 'informe o comando depois de "--". Ex.: Invoke-TrabalhoPesado.ps1 -- dotnet build'
}

if ($MemoriaGB -le 0) {
    $ram = [double](Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
    $MemoriaGB = [math]::Max(0.5, [math]::Round($ram * 0.4 / 1GB, 1))
}

# Resolve o executavel. Alias e funcao de perfil nao existem fora do pwsh.
$alvo = $tokens[0]
$resolvido = $null
if ($alvo.Contains('\') -or $alvo.Contains('/')) {
    if (Test-Path -LiteralPath $alvo -PathType Leaf) {
        $resolvido = [IO.Path]::GetFullPath($alvo)
    }
} else {
    $achado = @(Get-Command -Name $alvo -CommandType Application -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if (-not $achado) {
        $achado = @(Get-Command -Name $alvo -CommandType ExternalScript -ErrorAction SilentlyContinue) |
            Select-Object -First 1
    }
    if ($achado) { $resolvido = $achado.Source }
}
if (-not $resolvido) { Stop-Runner "comando nao encontrado como programa: $alvo" }

function ConvertTo-ArgumentoWindows {
    # Regras de CommandLineToArgvW: barras antes de aspas sao dobradas.
    param([string]$Text)
    if ($Text.Length -eq 0) { return '""' }
    if ($Text -notmatch '[\s"]') { return $Text }
    $escaped = [regex]::Replace($Text, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

$resto = @($tokens | Select-Object -Skip 1)
$extensao = [IO.Path]::GetExtension($resolvido).ToLowerInvariant()
switch ($extensao) {
    { $_ -in '.cmd', '.bat' } {
        $interno = (@($resolvido) + $resto | ForEach-Object { ConvertTo-ArgumentoWindows $_ }) -join ' '
        $exe = $env:ComSpec
        $linha = '"' + $exe + '" /d /s /c "' + $interno + '"'
    }
    '.ps1' {
        $exe = (Get-Process -Id $PID).Path
        $partes = @('-NoProfile', '-File', $resolvido) + $resto
        $linha = '"' + $exe + '" ' + (($partes | ForEach-Object { ConvertTo-ArgumentoWindows $_ }) -join ' ')
    }
    default {
        $exe = $resolvido
        $linha = (@($resolvido) + $resto | ForEach-Object { ConvertTo-ArgumentoWindows $_ }) -join ' '
    }
}

$comandoTexto = ($tokens -join ' ')
Write-Runner ("plano: comando [{0}]; CPU ate {1}% da maquina; memoria do job ate {2:0.0#} GB; {3} vaga(s) em {4}-N; espera maxima {5} min" -f `
    $comandoTexto, $CpuPorcento, $MemoriaGB, $Vagas, $NomeVaga, $EsperaMaxMinutos)
Write-Runner 'sem teto de I/O: o Windows nao oferece (nao suportado desde o Windows 10 1607).'

if ($WhatIf) {
    Write-Runner "What if: nada foi executado (-WhatIf)."
    return
}

if (-not ('GerenciadorComputador.TrabalhoPesadoJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace GerenciadorComputador
{
    public sealed class TrabalhoPesadoJob : IDisposable
    {
        const uint JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const uint CPU_RATE_ENABLE = 0x1;
        const uint CPU_RATE_HARD_CAP = 0x4;
        const int InfoExtendedLimit = 9;
        const int InfoCpuRate = 15;
        const int InfoAssociatePort = 7;
        const uint CREATE_SUSPENDED = 0x4;
        const uint STARTF_USESTDHANDLES = 0x100;
        const uint HANDLE_FLAG_INHERIT = 0x1;
        const uint MSG_PROCESS_MEMORY_LIMIT = 9;
        const uint MSG_JOB_MEMORY_LIMIT = 10;

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS { public ulong A, B, C, D, E, F; }

        [StructLayout(LayoutKind.Sequential)]
        struct BASIC_LIMIT
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EXTENDED_LIMIT
        {
            public BASIC_LIMIT Basic;
            public IO_COUNTERS Io;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct CPU_RATE { public uint ControlFlags; public uint CpuRate; }

        [StructLayout(LayoutKind.Sequential)]
        struct ASSOCIATE_PORT { public IntPtr CompletionKey; public IntPtr CompletionPort; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute;
            public uint dwFlags;
            public ushort wShowWindow, cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION
        {
            public IntPtr hProcess, hThread;
            public uint dwProcessId, dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int cls, ref EXTENDED_LIMIT info, int len);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int cls, ref CPU_RATE info, int len);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int cls, ref ASSOCIATE_PORT info, int len);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool QueryInformationJobObject(IntPtr job, int cls, out EXTENDED_LIMIT info, int len, IntPtr ret);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
            uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint ms);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int which);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr port, UIntPtr key, uint threads);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out UIntPtr key, out IntPtr ov, uint ms);

        IntPtr job = IntPtr.Zero;
        IntPtr port = IntPtr.Zero;
        IntPtr process = IntPtr.Zero;
        bool memoryLimitHit;
        ulong memoryLimitBytes;

        public bool MemoryLimitHit { get { return memoryLimitHit; } }

        static void Fail(string what)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), what);
        }

        public TrabalhoPesadoJob(ulong memoryBytes, uint cpuPercent)
        {
            memoryLimitBytes = memoryBytes;
            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) Fail("CreateJobObject");

            var ext = new EXTENDED_LIMIT();
            ext.Basic.LimitFlags = JOB_OBJECT_LIMIT_JOB_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            ext.JobMemoryLimit = new UIntPtr(memoryBytes);
            if (!SetInformationJobObject(job, InfoExtendedLimit, ref ext, Marshal.SizeOf(typeof(EXTENDED_LIMIT))))
                Fail("SetInformationJobObject(limites estendidos)");

            var cpu = new CPU_RATE();
            cpu.ControlFlags = CPU_RATE_ENABLE | CPU_RATE_HARD_CAP;
            cpu.CpuRate = cpuPercent * 100;
            if (!SetInformationJobObject(job, InfoCpuRate, ref cpu, Marshal.SizeOf(typeof(CPU_RATE))))
                Fail("SetInformationJobObject(teto de CPU)");

            // Porta de conclusao: o job avisa quando estoura o teto de memoria.
            port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
            if (port != IntPtr.Zero)
            {
                var assoc = new ASSOCIATE_PORT();
                assoc.CompletionKey = job;
                assoc.CompletionPort = port;
                SetInformationJobObject(job, InfoAssociatePort, ref assoc, Marshal.SizeOf(typeof(ASSOCIATE_PORT)));
            }
        }

        // Cria suspenso, coloca no job e so entao retoma: sem janela fora do teto.
        public void Start(string exe, string commandLine)
        {
            var si = new STARTUPINFO();
            si.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
            IntPtr hin = GetStdHandle(-10), hout = GetStdHandle(-11), herr = GetStdHandle(-12);
            foreach (var h in new[] { hin, hout, herr })
                if (h != IntPtr.Zero && h != new IntPtr(-1)) SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = hin; si.hStdOutput = hout; si.hStdError = herr;

            PROCESS_INFORMATION pi;
            var cmd = new StringBuilder(commandLine);
            if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED, IntPtr.Zero, null, ref si, out pi))
                Fail("CreateProcess");
            try
            {
                if (!AssignProcessToJobObject(job, pi.hProcess))
                {
                    int err = Marshal.GetLastWin32Error();
                    TerminateProcess(pi.hProcess, 1);   // so o filho recem-criado, ainda suspenso
                    CloseHandle(pi.hProcess);
                    throw new System.ComponentModel.Win32Exception(err, "AssignProcessToJobObject");
                }
                if (ResumeThread(pi.hThread) == 0xFFFFFFFF) Fail("ResumeThread");
                process = pi.hProcess;
            }
            finally
            {
                CloseHandle(pi.hThread);
            }
        }

        void Drain()
        {
            if (port == IntPtr.Zero) return;
            uint msg; UIntPtr key; IntPtr ov;
            while (GetQueuedCompletionStatus(port, out msg, out key, out ov, 0))
            {
                if (msg == MSG_JOB_MEMORY_LIMIT || msg == MSG_PROCESS_MEMORY_LIMIT) memoryLimitHit = true;
            }
        }

        // true quando o processo principal terminou.
        public bool Wait(uint ms)
        {
            uint r = WaitForSingleObject(process, ms);
            Drain();
            return r == 0;
        }

        public int ExitCode()
        {
            uint code;
            if (!GetExitCodeProcess(process, out code)) Fail("GetExitCodeProcess");
            return unchecked((int)code);
        }

        public ulong PeakBytes()
        {
            EXTENDED_LIMIT ext;
            if (!QueryInformationJobObject(job, InfoExtendedLimit, out ext, Marshal.SizeOf(typeof(EXTENDED_LIMIT)), IntPtr.Zero))
                return 0;
            Drain();
            ulong peak = ext.PeakJobMemoryUsed.ToUInt64();
            // Rede de seguranca caso a notificacao nao tenha chegado.
            if (memoryLimitBytes > 0 && peak >= memoryLimitBytes - memoryLimitBytes / 50) memoryLimitHit = true;
            return peak;
        }

        // Fechar o job com KILL_ON_JOB_CLOSE encerra a arvore inteira dele.
        public void Dispose()
        {
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (port != IntPtr.Zero) { CloseHandle(port); port = IntPtr.Zero; }
        }
    }
}
'@
}

# ----- vaga global (mutex nomeado, ciente de abandono) -----
$mutexes = @(1..$Vagas | ForEach-Object {
    [Threading.Mutex]::new($false, ('{0}-{1}' -f $NomeVaga, $_))
})
$mutexPego = $null
$relogio = [Diagnostics.Stopwatch]::StartNew()
$prazo = [TimeSpan]::FromMinutes($EsperaMaxMinutos)
$ultimoAviso = [TimeSpan]::Zero
$codigo = $ExitErro
$job = $null

try {
    while ($null -eq $mutexPego) {
        for ($i = 0; $i -lt $mutexes.Count; $i++) {
            $abandonado = $false
            try {
                $pegou = $mutexes[$i].WaitOne(0)
            } catch [Threading.AbandonedMutexException] {
                $pegou = $true
                $abandonado = $true
            }
            if ($pegou) {
                $mutexPego = $mutexes[$i]
                if ($abandonado) {
                    Write-Warning "vaga $($i + 1) estava abandonada (o dono anterior morreu sem liberar); assumida."
                }
                Write-Runner ("vaga {0} de {1} obtida apos {2:0} s" -f ($i + 1), $Vagas, $relogio.Elapsed.TotalSeconds)
                break
            }
        }
        if ($null -ne $mutexPego) { break }
        if ($relogio.Elapsed -ge $prazo) {
            [Console]::Error.WriteLine(("[trabalho-pesado] sem vaga apos {0} min; desistindo (codigo {1})." -f $EsperaMaxMinutos, $ExitEspera))
            $codigo = $ExitEspera
            exit $ExitEspera
        }
        if (($relogio.Elapsed - $ultimoAviso).TotalSeconds -ge 30 -or $ultimoAviso -eq [TimeSpan]::Zero) {
            Write-Runner ("aguardando vaga ha {0:0} s (maximo {1} min)..." -f $relogio.Elapsed.TotalSeconds, $EsperaMaxMinutos)
            $ultimoAviso = $relogio.Elapsed
        }
        Start-Sleep -Milliseconds 500
    }

    $bytes = [uint64]($MemoriaGB * 1GB)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = [GerenciadorComputador.TrabalhoPesadoJob]::new($bytes, [uint32]$CpuPorcento)
    $job.Start($exe, $linha)
    while (-not $job.Wait(250)) { }
    $sw.Stop()
    $codigo = $job.ExitCode()
    $pico = $job.PeakBytes()
    $teto = if ($job.MemoryLimitHit) { 'ATINGIDO' }
        elseif ($pico -ge 0.7 * $bytes) { 'nao notificado, mas o pico passou de 70% (runtimes como .NET recusam sozinhos perto de 75%)' }
        else { 'nao atingido' }
    Write-Runner ("resumo: duracao {0:hh\:mm\:ss\.f}; pico de memoria do job {1:0.0} MB de {2:0.0} MB; teto de memoria {3}; codigo de saida {4}" -f `
        $sw.Elapsed, ($pico / 1MB), ($bytes / 1MB), $teto, $codigo)
}
catch {
    [Console]::Error.WriteLine("[trabalho-pesado] erro: $($_.Exception.Message)")
    $codigo = $ExitErro
}
finally {
    # Fecha o job (mata o que sobrou dentro dele) e so depois devolve a vaga.
    if ($null -ne $job) { $job.Dispose() }
    if ($null -ne $mutexPego) { try { $mutexPego.ReleaseMutex() } catch { } }
    foreach ($m in $mutexes) { $m.Dispose() }
}
exit $codigo
