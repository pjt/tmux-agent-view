/**
 * Pi lifecycle adapter for tmux-agent-view.
 *
 * install-hooks.sh copies this file into Pi's global extension directory and
 * replaces the hook-path placeholder below. Keep this dependency-free so the
 * adapter does not depend on Pi's installed package name.
 */

import { spawnSync } from "node:child_process";

type ExtensionContext = {
  sessionManager: { getSessionId(): string };
};

type AgentMessage = {
  role?: string;
  stopReason?: string;
  errorMessage?: string;
};

type ExtensionAPI = {
  on(event: string, handler: (event: any, ctx: ExtensionContext) => void): void;
};

const installedHookPath = "__AGENT_VIEW_HOOK__";

export default function tmuxAgentView(pi: ExtensionAPI): void {
  let settledEvent = "Stop";
  let settledMessage = "";

  function emit(event: string, ctx: ExtensionContext, message = ""): void {
    if (!process.env.TMUX_PANE) return;

    const hookPath = process.env.TMUX_AGENT_VIEW_HOOK || installedHookPath;
    const payload = JSON.stringify({
      hook_event_name: event,
      session_id: ctx.sessionManager.getSessionId(),
      message,
    });

    // The shell hook performs an atomic state write and returns quickly. A
    // synchronous call guarantees that quit/session-switch events are not lost
    // while Pi tears down the extension runtime.
    spawnSync(hookPath, ["pi"], {
      input: payload,
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 10000,
    });
  }

  pi.on("session_start", (_event, ctx) => {
    emit("SessionStart", ctx);
  });

  pi.on("agent_start", (_event, ctx) => {
    settledEvent = "Stop";
    settledMessage = "";
    emit("UserPromptSubmit", ctx);
  });

  pi.on("agent_end", (event: { messages?: AgentMessage[] }) => {
    const messages = event.messages || [];
    const assistant = [...messages].reverse().find((message) => message.role === "assistant");

    if (assistant?.stopReason === "error") {
      settledEvent = "StopFailure";
      settledMessage = assistant.errorMessage || "Pi turn failed";
    } else if (assistant?.stopReason === "aborted") {
      settledEvent = "Interrupt";
      settledMessage = "Pi turn interrupted";
    }
  });

  // agent_end may be followed by an automatic retry, compaction, or queued
  // follow-up. agent_settled is the first reliable completion boundary.
  pi.on("agent_settled", (_event, ctx) => {
    emit(settledEvent, ctx, settledMessage);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    emit("SessionEnd", ctx);
  });
}
