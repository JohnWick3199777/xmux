import net from "node:net";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const portPath = process.env.XMUX_PORT ?? "";
const terminalId = process.env.XMUX_TERMINAL_ID ?? "";
const processId = process.pid;

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

function sanitize(value: unknown, seen = new WeakSet<object>()): JsonValue {
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
	if (Array.isArray(value)) return value.map((item) => sanitize(item, seen));
	if (value instanceof Date) return value.toISOString();
	if (Buffer.isBuffer(value) || value instanceof Uint8Array) {
		return {
			type: value.constructor.name,
			length: value.length,
			base64: Buffer.from(value).toString("base64"),
		};
	}
	if (typeof value !== "object") return String(value);
	if (seen.has(value)) return "[Circular]";
	seen.add(value);
	const output: Record<string, JsonValue> = {};
	for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
		output[key] = sanitize(item, seen);
	}
	return output;
}

function emit(method: string, payload: Record<string, unknown>) {
	if (!portPath) return;

	const message = JSON.stringify({ jsonrpc: "2.0", method, params: payload }) + "\n";
	const socket = net.createConnection(portPath);

	socket.on("error", () => {
		socket.destroy();
	});

	socket.on("connect", () => {
		socket.end(message);
	});
}

function contextExtras(pi: ExtensionAPI, ctx: any): Record<string, unknown> {
	return {
		session_file: ctx?.sessionManager?.getSessionFile?.() ?? null,
		session_name: pi.getSessionName?.() ?? null,
		model: ctx?.model ? { provider: ctx.model.provider, id: ctx.model.id } : null,
		is_idle: ctx?.isIdle?.() ?? null,
		has_pending_messages: ctx?.hasPendingMessages?.() ?? null,
	};
}

function shouldForwardEvent(type: string, event: unknown): boolean {
	if (type !== "message_update") return true;

	const assistantEvent = (event as any)?.assistantMessageEvent;
	const assistantType = assistantEvent?.type;
	if (!assistantType || typeof assistantType !== "string") return true;

	return ["text_end", "thinking_end", "toolcall_end", "done", "error"].includes(assistantType);
}

function emitEvent(type: string, event: unknown, pi: ExtensionAPI, ctx?: any) {
	if (!shouldForwardEvent(type, event)) return;

	emit(`pi.${type}`, {
		terminal_id: terminalId,
		pid: processId,
		cwd: process.cwd(),
		...contextExtras(pi, ctx),
		event: sanitize(event),
	});
}

function makePassiveHandler(type: string, pi: ExtensionAPI) {
	return async (event: Record<string, unknown> = {}, ctx?: any) => {
		emitEvent(type, event, pi, ctx);
		return undefined;
	};
}

export default function (pi: ExtensionAPI) {
	pi.on("resources_discover", makePassiveHandler("resources_discover", pi));
	pi.on("session_start", makePassiveHandler("session_start", pi));
	pi.on("session_before_switch", makePassiveHandler("session_before_switch", pi));
	pi.on("session_before_fork", makePassiveHandler("session_before_fork", pi));
	pi.on("session_before_compact", makePassiveHandler("session_before_compact", pi));
	pi.on("session_compact", makePassiveHandler("session_compact", pi));
	pi.on("session_before_tree", makePassiveHandler("session_before_tree", pi));
	pi.on("session_tree", makePassiveHandler("session_tree", pi));
	pi.on("session_shutdown", makePassiveHandler("session_shutdown", pi));
	pi.on("before_agent_start", makePassiveHandler("before_agent_start", pi));
	pi.on("agent_start", makePassiveHandler("agent_start", pi));
	pi.on("agent_end", makePassiveHandler("agent_end", pi));
	pi.on("turn_start", makePassiveHandler("turn_start", pi));
	pi.on("turn_end", makePassiveHandler("turn_end", pi));
	pi.on("message_start", makePassiveHandler("message_start", pi));
	pi.on("message_update", makePassiveHandler("message_update", pi));
	pi.on("message_end", makePassiveHandler("message_end", pi));
	pi.on("tool_execution_start", makePassiveHandler("tool_execution_start", pi));
	pi.on("tool_execution_update", makePassiveHandler("tool_execution_update", pi));
	pi.on("tool_execution_end", makePassiveHandler("tool_execution_end", pi));
	pi.on("context", makePassiveHandler("context", pi));
	pi.on("before_provider_request", makePassiveHandler("before_provider_request", pi));
	pi.on("model_select", makePassiveHandler("model_select", pi));
	pi.on("tool_call", makePassiveHandler("tool_call", pi));
	pi.on("tool_result", makePassiveHandler("tool_result", pi));
	pi.on("user_bash", makePassiveHandler("user_bash", pi));
	pi.on("input", makePassiveHandler("input", pi));
}
