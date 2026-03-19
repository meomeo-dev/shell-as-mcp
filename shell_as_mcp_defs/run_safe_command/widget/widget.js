(function () {
  const state = {
    requestId: "",
    command: "",
    args: [],
    workingDir: "",
    contextDigest: "",
    expiresAtMs: 0,
    timeoutHandle: null,
  };

  const els = {
    approveBtn: document.getElementById("approve-btn"),
    denyBtn: document.getElementById("deny-btn"),
    countdown: document.getElementById("countdown"),
    message: document.getElementById("auth-message"),
    command: document.getElementById("field-command"),
    args: document.getElementById("field-args"),
    workingDir: document.getElementById("field-working-dir"),
    digest: document.getElementById("field-digest"),
  };

  function msLeft() {
    return Math.max(0, state.expiresAtMs - Date.now());
  }

  function setMessage(text, isError) {
    els.message.textContent = text;
    els.message.style.color = isError ? "#b44734" : "#7a6a5f";
  }

  function setButtonsEnabled(enabled) {
    els.approveBtn.disabled = !enabled;
    els.denyBtn.disabled = !enabled;
  }

  function updateCountdown() {
    const left = msLeft();
    const seconds = Math.ceil(left / 1000);
    els.countdown.textContent = "Expires in " + seconds + "s";

    if (left <= 0) {
      setButtonsEnabled(false);
      setMessage("Ticket expired. Close this widget and request a new ticket.", true);
      clearInterval(state.timeoutHandle);
      state.timeoutHandle = null;
    } else if (left <= 30000) {
      setMessage("Authorization will expire soon.", false);
    }
  }

  async function executeWithDecision(decision) {
    if (!state.command || !state.workingDir) {
      setMessage("Missing command context.", true);
      return;
    }

    setButtonsEnabled(false);
    setMessage("Submitting authorization...", false);

    if (decision === "deny") {
      setMessage("Authorization denied.", true);
      return;
    }

    const payload = {
      command: state.command,
      args_json: JSON.stringify(state.args || []),
      working_dir: state.workingDir,
    };

    const fn = window.runSafeCommandExecute;
    if (typeof fn !== "function") {
      setButtonsEnabled(true);
      setMessage("Execute bridge not configured. Provide window.runSafeCommandExecute.", true);
      return;
    }

    try {
      const result = await fn(payload);
      if (result && (result.ok || result.taskId || result.content || result.structuredContent)) {
        setMessage("Execution authorized and submitted.", false);
      } else {
        setButtonsEnabled(true);
        setMessage("Execution request failed.", true);
      }
    } catch (error) {
      setButtonsEnabled(true);
      setMessage("Execution request failed.", true);
      console.error(error);
    }
  }

  function bindEvents() {
    els.approveBtn.addEventListener("click", function () {
      executeWithDecision("approve");
    });

    els.denyBtn.addEventListener("click", function () {
      executeWithDecision("deny");
    });

    window.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        executeWithDecision("deny");
      }
    });
  }

  function render() {
    els.command.textContent = state.command || "--";
    els.args.textContent = JSON.stringify(state.args || []);
    els.workingDir.textContent = state.workingDir || "--";
    els.digest.textContent = state.contextDigest || "--";
    updateCountdown();
    if (!state.timeoutHandle) {
      state.timeoutHandle = setInterval(updateCountdown, 1000);
    }
  }

  function setRequest(data) {
    state.requestId = String(data.request_id || "");
    state.command = String(data.command || "");
    state.args = Array.isArray(data.args) ? data.args : [];
    state.workingDir = String(data.working_dir || "");
    state.contextDigest = String(data.context_digest || "");
    state.expiresAtMs = Number(data.expires_at_ms || 0);
    setButtonsEnabled(msLeft() > 0);
    render();
  }

  bindEvents();
  window.runSafeCommandAuthWidget = {
    setRequest,
  };
})();
