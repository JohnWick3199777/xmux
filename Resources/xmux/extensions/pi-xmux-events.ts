import net from "node:net";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const portPath = process.env.XMUX_PORT ?? "";
const terminalId = process.env.XMUX_TERMINAL_ID ?? "";
const processId = process.pid;

function sanitize(value: unknown, seen = new WeakSet<object>()): unknown {
	if (value === null || value === undefined) return value ?? null;
	if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
	if (typeof value === "bigint") return value.toString();
	if (value instanceof Error) {
		return {
			name: value.name,
			message: value.message,
			stack: value.stack,
		};
	}
	if (typeof value !== "object") return String(value);
	if (seen.has(value as object)) return "[Circular]";
	seen.add(value as object);
	if (Array.isArray(value)) return value.map(item => sanitize(item, seen));
	const output: Record<string, unknown> = {};
	for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
		if (typeof item === "function") continue;
		output[key] = sanitize(item, seen);
	}
	return output;
}

function emit(method: string, payload: Record<string, unknown>) {
	if (!portPath) return;
	const message = JSON.stringify({
		jsonrpc: "2.0",
		method,
		params: payload,
	});

	try {
		const socket = net.createConnection(portPath);
		socket.on("connect", () => {
			socket.write(message + "\n");
			socket.end();
		});
		socket.on("error", () => {
			// Never let xmux event forwarding affect pi itself.
		});
	} catch {
		// Ignore transport failures.
	}
}

function emitEvent(type: string, event: unknown, ctx?: { sessionManager?: { getSessionFile?: () => string | undefined } }) {
	emit(`pi.${type}`, {
		terminal_id: terminalId,
		pid: processId,
		session_file: ctx?.sessionManager?.getSessionFile?.() ?? null,
		event: sanitize(event),
	});
}

export default function (pi: ExtensionAPI) {
	pi.on("session_start", async (event, ctx) => emitEvent("session_start", event, ctx));
	pi.on("session_before_switch", async (event, ctx) => emitEvent("session_before_switch", event, ctx));
	pi.on("session_before_fork", async (event, ctx) => emitEvent("session_before_fork", event, ctx));
	pi.on("session_before_compact", async (event, ctx) => emitEvent("session_before_compact", event, ctx));
	pi.on("session_compact", async (event, ctx) => emitEvent("session_compact", event, ctx));
	pi.on("session_before_tree", async (event, ctx) => emitEvent("session_before_tree", event, ctx));
	pi.on("session_tree", async (event, ctx) => emitEvent("session_tree", event, ctx));
	pi.on("session_shutdown", async (event, ctx) => emitEvent("session_shutdown", event, ctx));
	pi.on("before_agent_start", async (event, ctx) => emitEvent("before_agent_start", event, ctx));
	pi.on("agent_start", async (event, ctx) => emitEvent("agent_start", event, ctx));
	pi.on("agent_end", async (event, ctx) => emitEvent("agent_end", event, ctx));
	pi.on("turn_start", async (event, ctx) => emitEvent("turn_start", event, ctx));
	pi.on("turn_end", async (event, ctx) => emitEvent("turn_end", event, ctx));
	pi.on("message_start", async (event, ctx) => emitEvent("message_start", event, ctx));
	pi.on("message_update", async (event, ctx) => emitEvent("message_update", event, ctx));
	pi.on("message_end", async (event, ctx) => emitEvent("message_end", event, ctx));
	pi.on("tool_execution_start", async (event, ctx) => emitEvent("tool_execution_start", event, ctx));
	pi.on("tool_execution_update", async (event, ctx) => emitEvent("tool_execution_update", event, ctx));
	pi.on("tool_execution_end", async (event, ctx) => emitEvent("tool_execution_end", event, ctx));
	pi.on("model_select", async (event, ctx) => emitEvent("model_select", event, ctx));
}
