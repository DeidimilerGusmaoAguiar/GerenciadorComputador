(() => {
  "use strict";

  const viewState = {
    snapshot: null,
    metric: "cpu",
    selectedPid: null,
    area: "",
    retryTimer: null,
    cliSessionsByRoot: new Map(),
    actionToken: null,
    pendingTermination: null,
    terminationInFlight: false,
    actionMessage: "",
    history: {
      cpu: [],
      memory: [],
      disk: [],
      gpu: [],
      network: []
    }
  };

  const metricConfig = {
    cpu: {
      title: "CPU total",
      field: "CpuPercent",
      suffix: "%",
      decimals: 1,
      footnote:
        "CPU é normalizada pela capacidade total do computador, não por um único núcleo."
    },
    memory: {
      title: "Memória privada",
      field: "PrivateMB",
      suffix: " MB",
      decimals: 1,
      footnote:
        "Private Bytes representa memória comprometida exclusivamente pelo processo; Working Set é apenas a parte residente."
    },
    io: {
      title: "E/S do processo",
      field: "IoTotalMBps",
      suffix: " MB/s",
      decimals: 2,
      footnote:
        "E/S por PID inclui arquivo, dispositivo e outras operações. Ela é correlacionada com o disco, não tratada como prova."
    },
    gpu: {
      title: "GPU — motor máximo",
      field: "GpuPercent",
      suffix: "%",
      decimals: 1,
      footnote:
        "GPU segue a semântica do Gerenciador de Tarefas: mostra o motor mais ocupado, evitando somar engines que compartilham núcleos."
    },
    network: {
      title: "Conexões TCP",
      field: "EstablishedConnections",
      suffix: "",
      decimals: 0,
      footnote:
        "Conexões são atribuídas ao PID; throughput por processo não é inferido sem rastreamento ETW."
    }
  };

  const byId = (id) => document.getElementById(id);
  const clamp = (value, minimum, maximum) =>
    Math.min(maximum, Math.max(minimum, Number(value) || 0));

  const escapeHtml = (value) =>
    String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");

  const formatNumber = (value, decimals = 1) => {
    if (value === null || value === undefined || Number.isNaN(Number(value))) {
      return "—";
    }
    return Number(value).toLocaleString("pt-BR", {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals
    });
  };

  const processInitials = (name) => {
    const cleaned = String(name || "?")
      .replace(/\.exe$/i, "")
      .replace(/[^a-z0-9]/gi, "");
    return (cleaned.slice(0, 2) || "?").toUpperCase();
  };

  const processBaseName = (name) => String(name || "").replace(/\.exe$/i, "");

  const formatAge = (minutes) => {
    const value = Number(minutes);
    if (!Number.isFinite(value) || value < 0) {
      return "idade indisponível";
    }
    if (value < 60) {
      return `${Math.round(value)} min`;
    }
    if (value < 1440) {
      return `${formatNumber(value / 60, 1)} h`;
    }
    return `${formatNumber(value / 1440, 1)} d`;
  };

  const formatDateTime = (value) => {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "horário indisponível";
    }
    return date.toLocaleString("pt-BR", {
      dateStyle: "short",
      timeStyle: "medium"
    });
  };

  const lineageText = (lineage) =>
    (Array.isArray(lineage) ? lineage : [])
      .map((node) => `${processBaseName(node.Name)} [${Number(node.Id)}]`)
      .join(" → ");

  function updateConnectionState(kind, label) {
    const node = byId("live-state");
    node.classList.remove("connected", "error");
    if (kind) {
      node.classList.add(kind);
    }
    byId("live-label").textContent = label;
  }

  // A tela é dividida em áreas; só a ativa fica no DOM visível. A faixa viva do
  // topo continua atualizada em todas elas, para que trocar de área não custe a
  // leitura de relance do sistema.
  const areaOrder = ["visao", "clis", "processos", "diagnostico"];
  const areaStorageKey = "pulso-area";

  function areaFromHash() {
    const candidate = String(window.location.hash || "").replace(/^#/, "");
    return areaOrder.includes(candidate) ? candidate : "";
  }

  function storedArea() {
    try {
      const candidate = window.localStorage.getItem(areaStorageKey);
      return areaOrder.includes(candidate) ? candidate : "";
    } catch {
      // Navegador com armazenamento bloqueado não impede o painel de funcionar.
      return "";
    }
  }

  function activateArea(name, options = {}) {
    const area = areaOrder.includes(name) ? name : areaOrder[0];
    const { focusPanel = false, syncHash = true } = options;
    if (viewState.area === area) {
      return;
    }
    viewState.area = area;

    areaOrder.forEach((candidate) => {
      const tab = byId(`tab-${candidate}`);
      const panel = byId(`area-${candidate}`);
      const active = candidate === area;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
      panel.hidden = !active;
    });

    if (focusPanel) {
      byId(`area-${area}`).focus({ preventScroll: true });
    }
    if (syncHash && areaFromHash() !== area) {
      // replaceState evita empilhar uma entrada de histórico por clique.
      window.history.replaceState(null, "", `#${area}`);
    }
    try {
      window.localStorage.setItem(areaStorageKey, area);
    } catch {
      // Sem persistência a área volta ao padrão na próxima carga; nada além disso.
    }
  }

  function setTabBadge(area, text, tone) {
    const badge = byId(`badge-${area}`);
    if (!badge) {
      return;
    }
    const label = String(text ?? "").trim();
    badge.textContent = label;
    badge.hidden = label === "";
    badge.dataset.tone = tone || "neutral";
  }

  function initAreas() {
    areaOrder.forEach((candidate) => {
      byId(`tab-${candidate}`).addEventListener("click", () => {
        activateArea(candidate);
      });
    });

    byId("area-nav").addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 1, ArrowUp: -1 }[event.key];
      let target = "";
      if (step) {
        const current = areaOrder.indexOf(viewState.area);
        target = areaOrder[(current + step + areaOrder.length) % areaOrder.length];
      } else if (event.key === "Home") {
        target = areaOrder[0];
      } else if (event.key === "End") {
        target = areaOrder[areaOrder.length - 1];
      }
      if (!target) {
        return;
      }
      event.preventDefault();
      activateArea(target);
      byId(`tab-${target}`).focus();
    });

    window.addEventListener("hashchange", () => {
      const fromHash = areaFromHash();
      if (fromHash) {
        activateArea(fromHash, { focusPanel: true, syncHash: false });
      }
    });

    activateArea(areaFromHash() || storedArea() || areaOrder[0]);
  }

  function renderSparkline(resourceKey, value) {
    const history = viewState.history[resourceKey];
    history.push(clamp(value, 0, 100));
    if (history.length > 48) {
      history.shift();
    }

    const width = 240;
    const height = 48;
    const topPadding = 5;
    const bottomPadding = 2;
    const usableHeight = height - topPadding - bottomPadding;
    const denominator = Math.max(1, history.length - 1);
    const points = history.map((sample, index) => {
      const x = (index / denominator) * width;
      const y = topPadding + usableHeight * (1 - sample / 100);
      return [x, y];
    });

    if (points.length === 1) {
      points.push([width, points[0][1]]);
    }

    const linePath = points
      .map(([x, y], index) => `${index === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`)
      .join(" ");
    const fillPath = `${linePath} L${width},${height} L0,${height} Z`;
    byId(`${resourceKey}-spark-line`).setAttribute("d", linePath);
    byId(`${resourceKey}-spark-fill`).setAttribute("d", fillPath);
  }

  function renderOverview(snapshot) {
    const { Overall: overall } = snapshot;
    const level = String(overall.Level);
    const score = clamp(overall.Score, 0, 100);

    byId("overall-state").dataset.level = level;
    byId("overall-state").textContent = overall.State;
    byId("overall-summary").textContent = overall.Summary;
    byId("overall-score").textContent = Math.round(score).toString();

    const dial = byId("pressure-dial");
    dial.dataset.level = level;
    dial.style.setProperty("--pressure", score.toFixed(1));

    byId("strip-score").textContent = Math.round(score).toString();
    byId("strip-score-shell").dataset.level = level;
    byId("strip-state").dataset.level = level;
    byId("strip-state").textContent = overall.State;
  }

  function renderResources(snapshot) {
    snapshot.Resources.forEach((resource) => {
      const key = resource.Key;
      const card = document.querySelector(`.resource-card[data-resource="${key}"]`);
      if (!card) {
        return;
      }

      card.dataset.level = String(resource.Level);
      byId(`${key}-state`).textContent = resource.Available ? resource.State : "N/D";
      byId(`${key}-value`).textContent = resource.Available
        ? formatNumber(resource.Value, 1)
        : "N/D";
      byId(`${key}-detail`).textContent = resource.Detail;
      byId(`${key}-basis`).textContent = resource.Basis;
      renderSparkline(key, resource.Available ? resource.Score : 0);

      const meter = document.querySelector(`.strip-meter[data-resource="${key}"]`);
      if (meter) {
        meter.dataset.level = String(resource.Level);
        byId(`strip-${key}`).textContent = resource.Available
          ? `${formatNumber(resource.Value, 0)}%`
          : "N/D";
      }
    });
  }

  function renderCliTopProcesses(processes) {
    return (processes || [])
      .map((process) => {
        const lineage = lineageText(process.Lineage);
        return `
          <div class="cli-process-row">
            <div class="cli-process-name">
              <strong>${escapeHtml(processBaseName(process.Name))}</strong>
              <small>PID ${Number(process.Id)} · ${escapeHtml(process.Workload || "processo auxiliar")}</small>
            </div>
            <div class="cli-process-role" title="${escapeHtml(lineage)}">
              ${escapeHtml(lineage || `${processBaseName(process.ParentName)} [${Number(process.ParentId)}]`)}
            </div>
            <div class="cli-process-signals">
              CPU ${formatNumber(process.CpuPercent, 1)}% ·
              privada ${formatNumber(process.PrivateMB, 0)} MB ·
              E/S ${formatNumber(process.IoTotalMBps, 2)} MB/s
            </div>
          </div>
        `;
      })
      .join("");
  }

  function renderCliTermination(session, actionsEnabled) {
    const termination = session.Termination || {
      Eligible: false,
      Code: "identity_unverified",
      Label: "NÃO VERIFICADA",
      Reason: "A identidade completa da árvore não está disponível."
    };
    const eligible = termination.Eligible === true;
    const button = eligible
      ? `
          <button
            class="terminate-session-button"
            type="button"
            data-root-id="${Number(session.RootId)}"
            ${actionsEnabled ? "" : "disabled"}
          >
            ${actionsEnabled ? "Encerrar árvore" : "Ação desativada"}
          </button>
        `
      : "";

    return `
      <div class="cli-session-action" data-code="${escapeHtml(termination.Code)}">
        <p>${escapeHtml(termination.Reason)}</p>
        ${button}
      </div>
    `;
  }

  function renderCliPressure(snapshot) {
    const summary = snapshot.TerminalSummary || { Detected: false, Level: 0 };
    const sessions = Array.isArray(snapshot.CliSessions) ? snapshot.CliSessions : [];
    const actionsEnabled = snapshot.Actions?.ProcessTerminationEnabled === true;
    viewState.cliSessionsByRoot = new Map(
      sessions.map((session) => [Number(session.RootId), session])
    );
    const family = byId("terminal-family");
    family.classList.remove("skeleton");
    family.dataset.level = String(clamp(summary.Level, 0, 4));

    if (!summary.Detected) {
      family.innerHTML = `
        <div class="terminal-family-copy">
          <span class="session-state">NÃO DETECTADO</span>
          <h3>Windows Terminal não apareceu nesta amostra</h3>
          <p>CLIs executadas fora dele continuam listadas abaixo quando a árvore pode ser atribuída.</p>
        </div>
      `;
    } else {
      const attachedPrivateGB = Number(summary.AttachedTreesPrivateMB || 0) / 1024;
      const headline =
        Number(summary.Level) >= 3
          ? `O conjunto do Windows Terminal está ${summary.State}`
          : `Windows Terminal: ${summary.State}`;
      const reasons = (summary.Reasons || [])
        .slice(0, 3)
        .map((reason) => `<span>${escapeHtml(reason)}</span>`)
        .join("");

      family.innerHTML = `
        <div class="terminal-family-copy">
          <span class="session-state">${escapeHtml(summary.State)}</span>
          <h3>${escapeHtml(headline)}</h3>
          <p>
            ${formatNumber(summary.PrivateGB, 2)} GB privados em
            ${formatNumber(summary.ProcessCount, 0)} processos.
            O <code>WindowsTerminal.exe</code> e seus hosts usam
            ${formatNumber(summary.HostPrivateMB, 0)} MB; as árvores anexadas usam
            ${formatNumber(attachedPrivateGB, 2)} GB.
          </p>
          <div class="terminal-family-reasons">
            ${reasons || "<span>Nenhum limite de atenção foi cruzado nesta amostra.</span>"}
          </div>
        </div>
        <div class="terminal-family-metrics" aria-label="Consumo agregado do Windows Terminal">
          <div class="terminal-family-metric">
            <span>CPU da árvore</span>
            <strong>${formatNumber(summary.CpuPercent, 1)}%</strong>
          </div>
          <div class="terminal-family-metric">
            <span>Memória privada</span>
            <strong>${formatNumber(summary.PrivateGB, 2)} GB</strong>
          </div>
          <div class="terminal-family-metric">
            <span>Só hosts gráficos</span>
            <strong>${formatNumber(summary.HostPrivateMB, 0)} MB</strong>
          </div>
          <div class="terminal-family-metric">
            <span>Working Set*</span>
            <strong>${formatNumber(summary.WorkingSetGB, 2)} GB</strong>
          </div>
          <div class="terminal-family-metric">
            <span>E/S da árvore</span>
            <strong>${formatNumber(summary.IoTotalMBps, 2)} MB/s</strong>
          </div>
          <div class="terminal-family-metric">
            <span>Sessões / PIDs</span>
            <strong>${formatNumber(summary.SessionCount, 0)} / ${formatNumber(summary.ProcessCount, 0)}</strong>
          </div>
        </div>
      `;
    }

    const terminalCount = sessions.filter((session) => session.HostedByTerminal).length;
    const detachedCount = sessions.length - terminalCount;
    const criticalCount = sessions.filter((session) => Number(session.Level) >= 3).length;
    const attentionCount = sessions.filter((session) => Number(session.Level) === 2).length;
    const orphanCount = sessions.filter(
      (session) => session.Termination?.Eligible === true
    ).length;
    byId("cli-session-count").textContent =
      `${terminalCount} no Terminal${detachedCount ? ` · ${detachedCount} fora` : ""}`;
    byId("cli-critical-count").textContent =
      `${criticalCount} ${criticalCount === 1 ? "crítica" : "críticas"} · ` +
      `${attentionCount} em atenção`;
    // A aba precisa avisar sem obrigar a entrar nela: primeiro o que é crítico,
    // depois o que pede atenção, e só então a contagem de sessões.
    if (criticalCount > 0) {
      setTabBadge("clis", criticalCount, "critical");
    } else if (attentionCount > 0) {
      setTabBadge("clis", attentionCount, "attention");
    } else {
      setTabBadge("clis", sessions.length, "neutral");
    }
    byId("cli-action-status").textContent = viewState.actionMessage ||
      (actionsEnabled
        ? `${orphanCount} ${orphanCount === 1 ? "árvore órfã habilitada" : "árvores órfãs habilitadas"} para confirmação manual.`
        : `${orphanCount} ${orphanCount === 1 ? "árvore órfã detectada" : "árvores órfãs detectadas"}; encerramento desativado neste servidor.`);
    viewState.actionMessage = "";

    if (sessions.length === 0) {
      byId("cli-session-grid").innerHTML = `
        <div class="detail-empty">
          <span aria-hidden="true">○</span>
          <p>Nenhuma árvore de shell ou CLI pôde ser atribuída nesta amostra.</p>
        </div>
      `;
      return;
    }

    byId("cli-session-grid").innerHTML = sessions
      .map((session) => {
        const rootLabel = `${processBaseName(session.RootName)} [${Number(session.RootId)}]`;
        const primaryCli = Number(session.PrimaryCliId) > 0
          ? ` → ${session.CliName} [${Number(session.PrimaryCliId)}]`
          : "";
        const termination = session.Termination || {
          Code: "identity_unverified",
          Label: "NÃO VERIFICADA"
        };
        const managedParent = termination.Code === "managed_parent" && termination.ParentId
          ? `${processBaseName(termination.ParentName)} [${Number(termination.ParentId)}] → `
          : "";
        const lineage = session.HostedByTerminal
          ? `WindowsTerminal [${Number(session.TerminalId)}] → ${rootLabel}${primaryCli}`
          : `${managedParent}${session.CliName} [${Number(session.RootId)}] · sem ancestral Windows Terminal`;
        const reasons = (session.Reasons || [])
          .slice(0, 3)
          .map((reason) => `<li>${escapeHtml(reason)}</li>`)
          .join("");
        const topProcesses = session.TopProcesses || [];

        return `
          <article
            class="cli-session-card ${session.HostedByTerminal ? "" : "detached"}"
            data-level="${clamp(session.Level, 0, 4)}"
          >
            <div class="cli-session-head">
              <div>
                <div class="cli-session-badges">
                  <span class="session-state">${escapeHtml(session.State)}</span>
                  <span class="session-host ${session.HostedByTerminal ? "" : "detached"}">
                    ${session.HostedByTerminal ? "NO TERMINAL" : "FORA DO TERMINAL"}
                  </span>
                  <span
                    class="session-disposition"
                    data-code="${escapeHtml(termination.Code)}"
                  >
                    ${escapeHtml(termination.Label)}
                  </span>
                </div>
                <h3>${escapeHtml(session.CliName)}</h3>
                <p class="cli-session-lineage" title="${escapeHtml(lineage)}">
                  ${escapeHtml(lineage)}
                </p>
              </div>
              <span class="panel-count">${escapeHtml(formatAge(session.AgeMinutes))}</span>
            </div>
            <p class="cli-session-summary">${escapeHtml(session.Summary)}</p>
            <div class="cli-session-metrics">
              <div class="cli-session-metric">
                <span>CPU árvore</span>
                <strong>${formatNumber(session.CpuPercent, 1)}%</strong>
              </div>
              <div class="cli-session-metric">
                <span>Privada</span>
                <strong>${formatNumber(session.PrivateGB, 2)} GB</strong>
              </div>
              <div class="cli-session-metric">
                <span>Working Set*</span>
                <strong>${formatNumber(session.WorkingSetGB, 2)} GB</strong>
              </div>
              <div class="cli-session-metric">
                <span>E/S</span>
                <strong>${formatNumber(session.IoTotalMBps, 2)} MB/s</strong>
              </div>
              <div class="cli-session-metric">
                <span>Processos</span>
                <strong>${formatNumber(session.ProcessCount, 0)}</strong>
              </div>
            </div>
            ${reasons ? `<ul class="cli-session-reasons">${reasons}</ul>` : ""}
            ${renderCliTermination(session, actionsEnabled)}
            <details class="cli-process-details">
              <summary>Ver os ${topProcesses.length} PIDs que mais contribuem</summary>
              <div class="cli-process-list">
                ${renderCliTopProcesses(topProcesses)}
              </div>
            </details>
          </article>
        `;
      })
      .join("");
  }

  function renderInsights(snapshot) {
    const insights = snapshot.Insights || [];
    byId("insight-count").textContent =
      `${insights.length} ${insights.length === 1 ? "sinal" : "sinais"}`;
    setTabBadge(
      "diagnostico",
      insights.length || "",
      insights.some((insight) => Number(insight.Level) >= 3) ? "critical" : "neutral"
    );

    byId("insights-list").innerHTML = insights
      .map(
        (insight) => `
          <article class="insight" data-level="${clamp(insight.Level, 0, 4)}">
            <span class="insight-marker" aria-hidden="true"></span>
            <div>
              <h3>${escapeHtml(insight.Title)}</h3>
              <p>${escapeHtml(insight.Narrative)}</p>
              <small class="insight-evidence">${escapeHtml(insight.Evidence)}</small>
            </div>
            <div class="confidence" aria-label="Confiança da conclusão">
              <span>atribuição ${escapeHtml(insight.AttributionConfidence)}</span>
              <span>causa ${escapeHtml(insight.CauseConfidence)}</span>
            </div>
          </article>
        `
      )
      .join("");
  }

  function renderSampleContext(snapshot) {
    byId("collection-duration").textContent =
      `${formatNumber(snapshot.CollectionDurationMs / 1000, 1)} s`;
    const cadence = snapshot.Cadence;
    byId("refresh-interval").textContent = cadence?.Relaxed
      ? `${snapshot.RefreshSeconds} s (afrouxado por estar saudável)`
      : `${snapshot.RefreshSeconds} s`;

    const selfCost = snapshot.SelfCost;
    if (selfCost) {
      byId("self-cost").textContent =
        `${formatNumber(selfCost.SelfCpuPercent, 1)}% CPU · ` +
        `${formatNumber(selfCost.DutyPercent, 1)}% do ciclo · ` +
        `${formatNumber(selfCost.SelfPrivateMB, 0)} MB`;
      byId("self-cost-provider").textContent =
        `${formatNumber(selfCost.WmiProviderCpuPercent, 1)}% CPU em ` +
        `${selfCost.WmiProviderCount} processo(s)`;
    } else {
      byId("self-cost").textContent = "—";
      byId("self-cost-provider").textContent = "—";
    }

    const generated = new Date(snapshot.GeneratedAt);
    byId("last-update").textContent = generated.toLocaleTimeString("pt-BR", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    });

    const terminationEnabled = snapshot.Actions?.ProcessTerminationEnabled === true;
    byId("action-mode-title").textContent = terminationEnabled
      ? "Encerramento opt-in ativo"
      : "Somente leitura";
    byId("action-mode-detail").textContent = terminationEnabled
      ? "Somente árvores órfãs, revalidadas no clique, recebem confirmação de encerramento."
      : "Inicie com -EnableProcessTermination para habilitar apenas ações órfãs determinísticas.";

    const volumes = snapshot.Volumes || [];
    byId("volume-list").innerHTML = volumes
      .map((volume) => {
        const freePercent = clamp(volume.FreePercent, 0, 100);
        return `
          <div class="mini-volume">
            <strong>${escapeHtml(volume.Drive)}</strong>
            <span class="mini-track" title="${formatNumber(freePercent, 1)}% livre">
              <span style="width: ${freePercent}%"></span>
            </span>
            <span>${formatNumber(volume.FreeGB, 1)} GB livres</span>
          </div>
        `;
      })
      .join("");
  }

  function renderExclusions(snapshot) {
    const defender = snapshot.Defender || {};
    const homes = defender.CliHomes || [];
    const grid = byId("exclusion-grid");

    // Aba carregada antes deste painel existir continua funcionando: sem o
    // contêiner, esta seção apenas não é desenhada.
    if (!grid) {
      return;
    }

    if (defender.Available !== true) {
      byId("exclusion-count").textContent = "sem leitura";
      byId("exclusion-schedule").textContent =
        "O provedor do antimalware não respondeu nesta amostra.";
      grid.innerHTML = "";
      return;
    }

    const exposed = homes.filter((home) => home.Covered !== true);
    byId("exclusion-count").textContent = homes.length
      ? `${exposed.length} de ${homes.length} expostos`
      : "nenhum perfil encontrado";

    const scanNote = defender.ScanInProgress
      ? `Varredura ${escapeHtml(defender.ScanKind || "")} em andamento` +
        (defender.ScanElapsedMinutes >= 0 ? ` há ${formatAge(defender.ScanElapsedMinutes)}` : "") +
        (defender.ScanStartedAt ? `, desde ${escapeHtml(defender.ScanStartedAt)}` : "") +
        (defender.ScanSource ? ` (detectada por ${escapeHtml(defender.ScanSource)}).` : ".") +
        " Os campos de última varredura do provedor seguem descrevendo a anterior até esta terminar."
      : defender.NextScheduledScan
        ? `Próxima varredura completa: ${escapeHtml(defender.NextScheduledScan)}` +
          (defender.MinutesUntilNextScan >= 0
            ? ` (em ${formatAge(defender.MinutesUntilNextScan)}).`
            : ".")
        : "Sem agenda de varredura completa legível.";
    const idleNote = defender.ScanOnlyIfIdle
      ? "A política espera a máquina ficar ociosa."
      : "A política não espera a máquina ficar ociosa.";
    // Assinatura velha muda o significado de tudo o mais nesta seção: uma
    // varredura pesada com definição defasada custa o mesmo e protege menos.
    const signatureNote =
      defender.SignatureAgeDays === null || defender.SignatureAgeDays === undefined
        ? ""
        : ` Assinaturas com ${formatNumber(defender.SignatureAgeDays, 0)} dia(s)` +
          (defender.SignatureUpdatedAt ? `, de ${escapeHtml(defender.SignatureUpdatedAt)}` : "") +
          (defender.SignatureAgeDays >= 7 ? " — fora do esperado para atualização diária." : ".");
    byId("exclusion-schedule").textContent = `${scanNote} ${idleNote}${signatureNote}`;

    grid.innerHTML = homes
      .map(
        (home) => `
          <article class="exclusion-item" data-level="${home.Covered === true ? 0 : 3}">
            <div class="exclusion-item-head">
              <strong>${escapeHtml(home.Label)}</strong>
              <span>${home.Covered === true ? "coberto" : "exposto"}</span>
            </div>
            <small>${
              home.Covered === true
                ? `por ${escapeHtml(home.CoveredBy || "exclusão declarada")}`
                : "sem exclusão de caminho nem de processo"
            }</small>
            <small class="exclusion-source">origem: ${escapeHtml(home.Source)}</small>
          </article>
        `
      )
      .join("");
  }

  function renderDocker(snapshot) {
    const grid = byId("docker-grid");
    // Aba carregada antes deste painel existir continua funcionando: sem o
    // contêiner, esta seção apenas não é desenhada.
    if (!grid) {
      return;
    }
    const docker = snapshot.Docker || null;
    if (!docker) {
      byId("docker-count").textContent = "sem leitura";
      byId("docker-note").textContent =
        "A sondagem ainda não rodou nesta instância do painel.";
      grid.innerHTML = "";
      return;
    }

    const state = docker.EngineState || "indisponivel";
    const stateLabels = {
      desligado: "desligado",
      ocioso: "ocioso",
      ativo: `${docker.RunningCount} container(s)`,
      afogado: "AFOGADO",
      indisponivel: "indisponível"
    };
    byId("docker-count").textContent = stateLabels[state] || state;
    byId("docker-note").textContent =
      `${docker.Detail || ""}${docker.CheckedAt ? ` Sondado às ${docker.CheckedAt}.` : ""}`;

    const items = [];
    if (state === "afogado") {
      items.push({
        level: 4,
        title: "Motor sem resposta",
        value: "afogado",
        detail:
          "Não empilhe carga nova. O caminho de socorro é o wsl --shutdown, que exige aprovação nominal.",
        source: "sondagem com prazo estourado"
      });
    }
    if (docker.VmmemPresent) {
      const cores = docker.VmmemCores;
      const hasCores = cores !== null && cores !== undefined;
      items.push({
        level: hasCores && cores >= 3 ? 3 : hasCores && cores >= 1.5 ? 2 : 0,
        title: `VM do WSL2 (vmmem ${docker.VmmemPid})`,
        value: hasCores ? `${formatNumber(cores, 2)} núcleo(s)` : "aquecendo",
        detail:
          `${formatNumber(docker.VmmemWorkingSetMB ?? 0, 0)} MB residentes · ` +
          `${formatNumber(docker.VmmemPrivateMB ?? 0, 0)} MB privados`,
        source: "delta de CPU entre sondagens"
      });
    }
    const wsl = docker.WslConfig || {};
    if (wsl.Present === true) {
      const reclaimOk = wsl.ReclaimActive === true;
      items.push({
        level: reclaimOk ? 0 : 2,
        title: ".wslconfig vigente",
        value: `${wsl.MemoryGB ?? "?"} GB · ${wsl.Processors ?? "?"} CPUs`,
        detail: reclaimOk
          ? `reclaim ${wsl.ReclaimMode || "?"} ativo · swap ${wsl.SwapGB ?? "?"} GB`
          : "autoMemoryReclaim fora de [experimental] — o WSL ignora a chave e a RAM não volta",
        source: "arquivo do usuário"
      });
    }
    const containers = (docker.Containers || [])
      .slice()
      .sort((a, b) => (b.CpuPercent || 0) - (a.CpuPercent || 0))
      .slice(0, 6);
    for (const container of containers) {
      const cpu = container.CpuPercent ?? 0;
      const unbounded = container.Unbounded === true;
      items.push({
        level: cpu >= 150 || (unbounded && cpu >= 80) ? 3 : cpu >= 80 || unbounded ? 2 : 0,
        title: container.Name,
        value: `${formatNumber(cpu, 1)}% CPU`,
        detail:
          `${formatNumber(container.MemoryMB ?? 0, 0)} MB` +
          (container.MemoryLimitMB ? ` / ${formatNumber(container.MemoryLimitMB, 0)} MB` : "") +
          (unbounded ? " — sem teto de memória" : ""),
        source: "docker stats"
      });
    }
    if (docker.TestcontainersCount > 0) {
      items.push({
        level: 3,
        title: "Efêmeros de teste em execução",
        value: `${docker.TestcontainersCount}`,
        detail:
          (docker.Testcontainers || []).map((tc) => tc.Name).slice(0, 5).join(", ") +
          " — vazamento se persistirem depois da suíte",
        source: "label org.testcontainers"
      });
    }
    if (typeof docker.DanglingVolumes === "number" && docker.DanglingVolumes > 0) {
      items.push({
        level: 1,
        title: "Volumes sem dono",
        value: `${docker.DanglingVolumes}`,
        detail: "Candidatos a remoção aprovada; o painel não remove nada.",
        source: "docker volume ls dangling"
      });
    }
    if (docker.VhdxSizeGB > 0) {
      items.push({
        level: 0,
        title: "Arquivo de dados (VHDX)",
        value: `${formatNumber(docker.VhdxSizeGB, 1)} GB`,
        detail: "Só encolhe com compactação aprovada, com o Docker parado.",
        source: "tamanho no disco do host"
      });
    }

    grid.innerHTML = items
      .map(
        (item) => `
          <article class="exclusion-item" data-level="${clamp(item.level, 0, 4)}">
            <div class="exclusion-item-head">
              <strong>${escapeHtml(item.title)}</strong>
              <span>${escapeHtml(item.value)}</span>
            </div>
            <small>${escapeHtml(item.detail)}</small>
            <small class="exclusion-source">${escapeHtml(item.source)}</small>
          </article>
        `
      )
      .join("");
  }

  function renderScanCost(snapshot) {
    const cost = snapshot.ScanCost;
    const processList = byId("scancost-processes");
    const pathList = byId("scancost-paths");
    if (!processList || !pathList) {
      return;
    }

    if (!cost || cost.Available !== true) {
      byId("scancost-count").textContent = "sem leitura";
      byId("scancost-note").textContent =
        (cost && cost.Detail) ||
        "Nada medido ainda: a leitura só acontece com o motor do antimalware trabalhando.";
      processList.innerHTML = "";
      pathList.innerHTML = "";
      return;
    }

    byId("scancost-count").textContent = `${formatNumber(cost.TotalSeconds, 0)} s medidos`;
    byId("scancost-note").textContent =
      `Janela desde ${escapeHtml(cost.WindowStart)}, ${cost.Samples} registro(s)` +
      (cost.MeasuredAt ? `, lido em ${escapeHtml(cost.MeasuredAt)}.` : ".");

    processList.innerHTML = (cost.Processes || [])
      .map(
        (item) => `
          <article class="scancost-item" data-level="${item.ExcludedProcess ? 0 : 2}">
            <div class="exclusion-item-head">
              <strong>${escapeHtml(item.Name)}</strong>
              <span>${formatNumber(item.Seconds, 0)} s</span>
            </div>
            <small>${formatNumber(item.Files, 0)} arquivo(s) · impacto máx ${item.MaxImpact}%</small>
            <small class="exclusion-source">${
              item.ExcludedProcess ? "processo já excluído" : "processo sem exclusão declarada"
            }</small>
          </article>
        `
      )
      .join("");

    pathList.innerHTML = (cost.Paths || [])
      .map(
        (item) => `
          <article class="scancost-item" data-level="${item.Covered ? 0 : 3}">
            <div class="exclusion-item-head">
              <strong>${escapeHtml(item.Label)}</strong>
              <span>${formatNumber(item.Seconds, 0)} s</span>
            </div>
            <small>${item.Covered ? "coberto por exclusão" : "exposto à varredura"}${
              item.Category ? ` · ${escapeHtml(item.Category)}` : ""
            }</small>
            ${
              item.Suggestion
                ? `<small class="scancost-suggestion">padrão sugerido: <code>${escapeHtml(
                    item.Suggestion
                  )}</code></small>`
                : ""
            }
            ${item.Rationale ? `<small class="exclusion-source">${escapeHtml(item.Rationale)}</small>` : ""}
          </article>
        `
      )
      .join("");
  }

  function renderCapabilities(snapshot) {
    byId("capability-grid").innerHTML = (snapshot.Capabilities || [])
      .map(
        (capability) => `
          <article class="capability ${capability.Available ? "available" : ""}">
            <span class="capability-status">
              ${capability.Available ? "DISPONÍVEL" : "OPCIONAL"}
            </span>
            <h3>${escapeHtml(capability.Label)}</h3>
            <p>${escapeHtml(capability.Detail)}</p>
          </article>
        `
      )
      .join("");
  }

  function metricMaximum(processes, field) {
    if (field === "CpuPercent" || field === "GpuPercent") {
      return 100;
    }
    return Math.max(1, ...processes.map((process) => Number(process[field]) || 0));
  }

  function otherSignals(process) {
    const parts = [];
    if (process.CpuPercent > 0) {
      parts.push(`CPU ${formatNumber(process.CpuPercent, 1)}%`);
    }
    if (process.PrivateMB > 0) {
      parts.push(`RAM ${formatNumber(process.PrivateMB, 0)} MB`);
    }
    if (process.IoTotalMBps >= 0.01) {
      parts.push(`E/S ${formatNumber(process.IoTotalMBps, 2)} MB/s`);
    }
    if (process.GpuPercent > 0) {
      parts.push(`GPU ${formatNumber(process.GpuPercent, 1)}%`);
    }
    return parts.slice(0, 3).join(" · ") || "sem outro sinal relevante";
  }

  function renderConsumers() {
    const snapshot = viewState.snapshot;
    if (!snapshot) {
      return;
    }

    const config = metricConfig[viewState.metric];
    const processes = snapshot.Consumers[viewState.metric] || [];
    const maximum = metricMaximum(processes, config.field);
    byId("metric-column-title").textContent = config.title;
    byId("table-footnote").textContent = config.footnote;

    if (processes.length === 0) {
      byId("consumer-rows").innerHTML = `
        <tr>
          <td colspan="4" class="context-cell">Nenhum processo com atividade mensurável nesta categoria.</td>
        </tr>
      `;
      byId("process-detail").innerHTML = `
        <div class="detail-empty">
          <span aria-hidden="true">○</span>
          <p>Nenhuma atividade desta categoria apareceu na amostra atual.</p>
        </div>
      `;
      return;
    }

    byId("consumer-rows").innerHTML = processes
      .map((process) => {
        const value = Number(process[config.field]) || 0;
        const barWidth = clamp((100 * value) / maximum, 0, 100);
        const isSelected = Number(viewState.selectedPid) === Number(process.Id);
        const ownerContext = process.OwningCliName
          ? `Árvore ${process.OwningCliName} · CLI PID ${Number(process.OwningCliId)}`
          : process.TerminalHosted
            ? `Sessão do Windows Terminal · raiz PID ${Number(process.TerminalSessionRootId)}`
            : process.Purpose;
        return `
          <tr data-pid="${Number(process.Id)}" class="${isSelected ? "selected" : ""}" tabindex="0">
            <td>
              <div class="process-cell">
                <span class="process-avatar">${escapeHtml(processInitials(process.Name))}</span>
                <span>
                  <span class="process-name">
                    ${escapeHtml(process.Name)}
                    ${process.Protected ? '<small class="protected-badge">PROTEGIDO</small>' : ""}
                  </span>
                  <small class="process-pid">PID ${Number(process.Id)}</small>
                </span>
              </div>
            </td>
            <td class="context-cell">
              <strong>${escapeHtml(process.Workload || process.Category)}</strong>
              ${escapeHtml(ownerContext)}
            </td>
            <td>
              <span class="metric-value">
                ${formatNumber(value, config.decimals)}${escapeHtml(config.suffix)}
              </span>
              <span class="metric-bar"><span style="width: ${barWidth}%"></span></span>
            </td>
            <td class="other-signals">${escapeHtml(otherSignals(process))}</td>
          </tr>
        `;
      })
      .join("");

    document.querySelectorAll("#consumer-rows tr[data-pid]").forEach((row) => {
      const select = () => selectProcess(Number(row.dataset.pid));
      row.addEventListener("click", select);
      row.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          select();
        }
      });
    });

    const selected = processes.find(
      (process) => Number(process.Id) === Number(viewState.selectedPid)
    );
    if (selected) {
      renderProcessDetail(selected);
    } else {
      byId("process-detail").innerHTML = `
        <div class="detail-empty">
          <span aria-hidden="true">↗</span>
          <p>Selecione um processo para ver a relação com pai, categoria e sinais medidos.</p>
        </div>
      `;
    }
  }

  function selectProcess(pid) {
    viewState.selectedPid = pid;
    renderConsumers();
  }

  function renderProcessDetail(process) {
    const parent = process.ParentName
      ? `${escapeHtml(process.ParentName)} · PID ${Number(process.ParentId)}`
      : "pai não disponível na amostra";
    const gpuEngine = process.GpuEngine
      ? ` · ${escapeHtml(process.GpuEngine)}`
      : "";
    const lineage = lineageText(process.Lineage);
    const cliOwner = process.OwningCliName
      ? `${escapeHtml(process.OwningCliName)} · PID ${Number(process.OwningCliId)}`
      : "nenhuma CLI reconhecida na cadeia";

    byId("process-detail").innerHTML = `
      <div class="detail-head">
        <span class="process-avatar">${escapeHtml(processInitials(process.Name))}</span>
        <div>
          <h3>${escapeHtml(process.Name)}</h3>
          <p>${escapeHtml(process.Category)} · PID ${Number(process.Id)}</p>
        </div>
      </div>
      <p class="detail-purpose">${escapeHtml(process.Purpose)}</p>
      <div class="detail-grid">
        <div class="detail-metric">
          <span>CPU total</span>
          <strong>${formatNumber(process.CpuPercent, 1)}%</strong>
        </div>
        <div class="detail-metric">
          <span>Memória privada</span>
          <strong>${formatNumber(process.PrivateMB, 1)} MB</strong>
        </div>
        <div class="detail-metric">
          <span>E/S total</span>
          <strong>${formatNumber(process.IoTotalMBps, 2)} MB/s</strong>
        </div>
        <div class="detail-metric">
          <span>GPU</span>
          <strong>${formatNumber(process.GpuPercent, 1)}%${gpuEngine}</strong>
        </div>
        <div class="detail-metric">
          <span>Memória GPU</span>
          <strong>${formatNumber(process.GpuMemoryMB, 1)} MB</strong>
        </div>
        <div class="detail-metric">
          <span>Conexões TCP</span>
          <strong>${formatNumber(process.EstablishedConnections, 0)}</strong>
        </div>
      </div>
      <p class="detail-parent"><strong>Processo pai:</strong> ${parent}</p>
      <p class="detail-parent"><strong>CLI responsável:</strong> ${cliOwner}</p>
      ${
        lineage
          ? `<p class="detail-parent"><strong>Linha da sessão:</strong> ${escapeHtml(lineage)}</p>`
          : ""
      }
      ${
        process.Protected
          ? '<p class="detail-parent"><strong>Protegido:</strong> sessões do Terminal e a árvore do dashboard nunca recebem ação de encerramento.</p>'
          : ""
      }
    `;
  }

  function closeTerminationDialog(force = false) {
    if (viewState.terminationInFlight && !force) {
      return;
    }
    const dialog = byId("termination-dialog");
    if (dialog.open) {
      dialog.close();
    }
    viewState.pendingTermination = null;
    byId("termination-consent").checked = false;
    byId("termination-confirm").disabled = true;
    byId("termination-result").textContent = "";
  }

  function openTerminationDialog(session) {
    const termination = session?.Termination;
    if (!termination || termination.Eligible !== true) {
      return;
    }

    viewState.pendingTermination = session;
    byId("termination-session").textContent =
      `${session.CliName} · PID ${Number(session.RootId)}`;
    byId("termination-started").textContent =
      formatDateTime(termination.RootStartedAt);
    byId("termination-processes").textContent =
      `${Number(termination.ProcessCount)} PIDs validados`;
    byId("termination-memory").textContent =
      `${formatNumber(session.PrivateGB, 2)} GB privados · ` +
      `${formatNumber(session.WorkingSetGB, 2)} GB de working set`;
    byId("termination-consent").checked = false;
    byId("termination-confirm").disabled = true;
    byId("termination-confirm").textContent =
      `Encerrar ${Number(termination.ProcessCount)} PIDs exatos`;
    byId("termination-result").textContent = "";
    byId("termination-dialog").showModal();
  }

  async function getActionToken() {
    if (viewState.actionToken) {
      return viewState.actionToken;
    }

    const response = await fetch("/api/action-token", {
      cache: "no-store",
      headers: { Accept: "application/json" }
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok || !body.Token) {
      throw new Error(body.Message || "O servidor não liberou o token efêmero de ação.");
    }
    viewState.actionToken = String(body.Token);
    return viewState.actionToken;
  }

  async function terminatePendingSession() {
    const session = viewState.pendingTermination;
    const termination = session?.Termination;
    if (
      !session ||
      !termination ||
      termination.Eligible !== true ||
      !byId("termination-consent").checked ||
      viewState.terminationInFlight
    ) {
      return;
    }

    window.clearTimeout(viewState.retryTimer);
    viewState.terminationInFlight = true;
    byId("termination-confirm").disabled = true;
    byId("termination-cancel").disabled = true;
    byId("termination-close").disabled = true;
    byId("termination-result").textContent =
      "Revalidando PID, início, pai, árvore e proteção do dashboard…";

    try {
      const actionToken = await getActionToken();
      const response = await fetch("/api/cli-sessions/terminate", {
        method: "POST",
        cache: "no-store",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-Pressure-Action-Token": actionToken
        },
        body: JSON.stringify({
          RootId: Number(session.RootId),
          RootStartedAt: termination.RootStartedAt,
          ExpectedFingerprint: termination.Fingerprint,
          ExpectedProcessCount: Number(termination.ProcessCount),
          Confirmed: true
        })
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) {
        if (response.status === 403) {
          viewState.actionToken = null;
        }
        throw new Error(
          result.Message ||
          "A revalidação recusou a ação; nenhum PID adicional foi inferido como alvo."
        );
      }

      viewState.actionMessage =
        result.Message || `Árvore PID ${Number(session.RootId)} processada.`;
      viewState.terminationInFlight = false;
      closeTerminationDialog(true);
      await loadSnapshot();
    } catch (error) {
      byId("termination-result").textContent = error.message;
      viewState.retryTimer = window.setTimeout(loadSnapshot, 5000);
    } finally {
      viewState.terminationInFlight = false;
      byId("termination-cancel").disabled = false;
      byId("termination-close").disabled = false;
      if (byId("termination-dialog").open) {
        byId("termination-confirm").disabled =
          !byId("termination-consent").checked;
      }
    }
  }

  function render(snapshot) {
    viewState.snapshot = snapshot;
    renderOverview(snapshot);
    renderResources(snapshot);
    renderCliPressure(snapshot);
    renderInsights(snapshot);
    renderSampleContext(snapshot);
    renderExclusions(snapshot);
    renderScanCost(snapshot);
    renderDocker(snapshot);
    renderCapabilities(snapshot);
    renderConsumers();
  }

  async function loadSnapshot() {
    window.clearTimeout(viewState.retryTimer);
    updateConnectionState("", "Coletando");

    try {
      const response = await fetch("/api/snapshot", {
        cache: "no-store",
        headers: { Accept: "application/json" }
      });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const snapshot = await response.json();
      render(snapshot);
      updateConnectionState("connected", "Ao vivo");

      const interval = Math.max(2000, Number(snapshot.RefreshSeconds) * 1000);
      viewState.retryTimer = window.setTimeout(loadSnapshot, interval);
    } catch (error) {
      updateConnectionState("error", "Sem leitura");
      byId("overall-summary").textContent =
        "O coletor local não respondeu. O painel tentará novamente sem alterar o computador.";
      viewState.retryTimer = window.setTimeout(loadSnapshot, 5000);
    }
  }

  initAreas();

  document.querySelectorAll(".metric-tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".metric-tab").forEach((candidate) => {
        const active = candidate === tab;
        candidate.classList.toggle("active", active);
        candidate.setAttribute("aria-selected", String(active));
      });
      viewState.metric = tab.dataset.metric;
      viewState.selectedPid = null;
      renderConsumers();
    });
  });

  byId("cli-session-grid").addEventListener("click", (event) => {
    const button = event.target.closest(".terminate-session-button");
    if (!button || button.disabled) {
      return;
    }
    const session = viewState.cliSessionsByRoot.get(Number(button.dataset.rootId));
    openTerminationDialog(session);
  });

  byId("termination-consent").addEventListener("change", (event) => {
    byId("termination-confirm").disabled =
      !event.target.checked || viewState.terminationInFlight;
  });
  byId("termination-confirm").addEventListener("click", terminatePendingSession);
  byId("termination-cancel").addEventListener("click", () => {
    closeTerminationDialog();
  });
  byId("termination-close").addEventListener("click", () => {
    closeTerminationDialog();
  });
  byId("termination-dialog").addEventListener("cancel", (event) => {
    if (viewState.terminationInFlight) {
      event.preventDefault();
      return;
    }
    closeTerminationDialog();
  });

  loadSnapshot();
})();
