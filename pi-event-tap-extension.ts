import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { appendFileSync, mkdirSync } from "node:fs";
import net from "node:net";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

function expandHome(path: string): string {
	if (path === "~") return homedir();
	if (path.startsWith("~/")) return resolve(homedir(), path.slice(2));
	return path;
}

function resolveEnvPath(primary: string, secondary?: string): string | undefined {
	const value = process.env[primary]?.trim() || (secondary ? process.env[secondary]?.trim() : "");
	if (!value) return undefined;
	return resolve(expandHome(value));
}

function getEventsFile(): string {
	return resolveEnvPath("PI_TAP_EVENTS_FILE", "XPI_EVENTS_FILE") ?? resolve(`/tmp/xpi-events-${process.pid}.jsonl`);
}

function shouldForwardToXmux(): boolean {
	const value = process.env.PI_TAP_FORWARD_TO_XMUX?.trim();
	if (value === "0" || value === "false") return false;
	return Boolean(process.env.XMUX_PORT?.trim());
}

const eventsFile = getEventsFile();
const xmuxPort = process.env.XMUX_PORT?.trim();
const xmuxTerminalId = process.env.XMUX_TERMINAL_ID?.trim();
const forwardToXmux = shouldForwardToXmux();
mkdirSync(dirname(eventsFile), { recursive: true });

function safeSerialize(value: unknown, seen = new WeakSet<object>()): JsonValue {
	if (value === null || value === undefined) return null;
	if (typeof value === "string" || typeof value === "boolean") return value;
	if (typeof value === "number") return Number.isFinite(value) ? value : String(value);
	if (typeof value === "bigint") return value.toString();
	if (typeof value === "function" || typeof value === "symbol") return String(value);

	if (value instanceof Error) {
		return {
			name: value.name,
			message: value.message,
			stack: value.stack ?? null,
		};
	}

	if (Array.isArray(value)) {
		return value.map((item) => safeSerialize(item, seen));
	}

	if (value instanceof Date) {
		return value.toISOString();
	}

	if (Buffer.isBuffer(value) || value instanceof Uint8Array) {
		return {
			type: value.constructor.name,
			length: value.length,
			base64: Buffer.from(value).toString("base64"),
		};
	}

	if (typeof value === "object") {
		if (seen.has(value)) return "[Circular]";
		seen.add(value);

		const output: Record<string, JsonValue> = {};
		for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
			output[key] = safeSerialize(entry, seen);
		}
		return output;
	}

	return String(value);
}

function appendJsonl(record: Record<string, unknown>): void {
	appendFileSync(eventsFile, JSON.stringify(record) + "\n", "utf8");
}

function forwardJsonRpc(method: string, params: Record<string, unknown>): void {
	if (!forwardToXmux || !xmuxPort) return;

	const payload = JSON.stringify({
		jsonrpc: "2.0",
		method,
		params,
	});

	const socket = net.createConnection(xmuxPort);
	socket.on("error", () => {
		socket.destroy();
	});
	socket.on("connect", () => {
		socket.end(payload + "\n");
	});
}

function buildEnvelope(type: string, payload: Record<string, unknown> = {}, extras: Record<string, unknown> = {}) {
	const tapTimestamp = Date.now();
	return {
		type,
		...payload,
		...extras,
		tapTimestamp,
		tapPid: process.pid,
		eventsFile,
		xmuxPort: xmuxPort ?? null,
		xmuxTerminalId: xmuxTerminalId ?? null,
		cwd: process.cwd(),
	};
}

function shouldForwardToXmuxPort(type: string, payload: Record<string, unknown>): boolean {
	if (type !== "message_update") return true;

	const assistantEvent = payload.assistantMessageEvent as Record<string, unknown> | undefined;
	const assistantType = assistantEvent?.type;
	if (typeof assistantType !== "string") return true;

	return ["text_end", "thinking_end", "toolcall_end", "done", "error"].includes(assistantType);
}

function writeEvent(type: string, payload: Record<string, unknown> = {}, extras: Record<string, unknown> = {}): void {
	const envelope = buildEnvelope(type, safeSerialize(payload) as Record<string, unknown>, safeSerialize(extras) as Record<string, unknown>);
	appendJsonl(envelope);

	if (!shouldForwardToXmuxPort(type, payload)) return;

	forwardJsonRpc(`pi.${type}`, {
		terminal_id: xmuxTerminalId ?? null,
		pid: process.pid,
		session_file: extras.sessionFile ?? null,
		session_name: extras.sessionName ?? null,
		cwd: process.cwd(),
		event: envelope,
	});
}

function makePassiveHandler(type: string, getExtras?: (ctx: unknown) => Record<string, unknown>) {
	return async (event: Record<string, unknown> = {}, ctx?: unknown) => {
		writeEvent(type, event, getExtras?.(ctx) ?? {});
		return undefined;
	};
}

function contextExtras(pi: ExtensionAPI, ctx: any): Record<string, unknown> {
	return {
		sessionFile: ctx?.sessionManager?.getSessionFile?.() ?? null,
		sessionName: pi.getSessionName() ?? null,
		model: ctx?.model ? { provider: ctx.model.provider, id: ctx.model.id } : null,
		isIdle: ctx?.isIdle?.() ?? null,
		hasPendingMessages: ctx?.hasPendingMessages?.() ?? null,
	};
}

export default function (pi: ExtensionAPI) {
	const extras = (ctx: any) => contextExtras(pi, ctx);

	writeEvent("tap_ready", {
		subscribedEvents: [
			"resources_discover",
			"session_start",
			"session_before_switch",
			"session_before_fork",
			"session_before_compact",
			"session_compact",
			"session_before_tree",
			"session_tree",
			"session_shutdown",
			"before_agent_start",
			"agent_start",
			"agent_end",
			"turn_start",
			"turn_end",
			"message_start",
			"message_update",
			"message_end",
			"tool_execution_start",
			"tool_execution_update",
			"tool_execution_end",
			"context",
			"before_provider_request",
			"model_select",
			"tool_call",
			"tool_result",
			"user_bash",
			"input",
		],
	});

	pi.on("resources_discover", makePassiveHandler("resources_discover", extras));
	pi.on("session_start", makePassiveHandler("session_start", extras));
	pi.on("session_before_switch", makePassiveHandler("session_before_switch", extras));
	pi.on("session_before_fork", makePassiveHandler("session_before_fork", extras));
	pi.on("session_before_compact", makePassiveHandler("session_before_compact", extras));
	pi.on("session_compact", makePassiveHandler("session_compact", extras));
	pi.on("session_before_tree", makePassiveHandler("session_before_tree", extras));
	pi.on("session_tree", makePassiveHandler("session_tree", extras));
	pi.on("session_shutdown", makePassiveHandler("session_shutdown", extras));

	pi.on("before_agent_start", makePassiveHandler("before_agent_start", extras));
	pi.on("agent_start", makePassiveHandler("agent_start", extras));
	pi.on("agent_end", makePassiveHandler("agent_end", extras));
	pi.on("turn_start", makePassiveHandler("turn_start", extras));
	pi.on("turn_end", makePassiveHandler("turn_end", extras));
	pi.on("message_start", makePassiveHandler("message_start", extras));
	pi.on("message_update", makePassiveHandler("message_update", extras));
	pi.on("message_end", makePassiveHandler("message_end", extras));

	pi.on("tool_execution_start", makePassiveHandler("tool_execution_start", extras));
	pi.on("tool_execution_update", makePassiveHandler("tool_execution_update", extras));
	pi.on("tool_execution_end", makePassiveHandler("tool_execution_end", extras));
	pi.on("tool_call", makePassiveHandler("tool_call", extras));
	pi.on("tool_result", makePassiveHandler("tool_result", extras));

	pi.on("context", makePassiveHandler("context", extras));
	pi.on("before_provider_request", makePassiveHandler("before_provider_request", extras));
	pi.on("model_select", makePassiveHandler("model_select", extras));
	pi.on("user_bash", makePassiveHandler("user_bash", extras));
	pi.on("input", makePassiveHandler("input", extras));

	pi.registerCommand("tap-path", {
		description: "Show the active xpi event tap destinations",
		handler: async (_args, ctx) => {
			const destinations = [`xpi event tap: ${eventsFile}`];
			if (xmuxPort) destinations.push(`xmux port: ${xmuxPort}`);
			ctx.ui.notify(destinations.join(" | "), "info");
		},
	});
}
