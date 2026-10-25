import { expect, test } from "bun:test";

test("MCP exposes selection and sudo without credential-reading tools", async () => {
  const child = Bun.spawn([".build/debug/WardCLI", "mcp"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  const reader = child.stdout.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  let id = 0;
  async function call(method: string, params: object = {}) {
    const requestID = ++id;
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: requestID, method, params }) + "\n");
    await child.stdin.flush();
    while (!buffered.includes("\n")) {
      const chunk = await reader.read();
      if (chunk.done) throw new Error("MCP exited before replying");
      buffered += decoder.decode(chunk.value, { stream: true });
    }
    const newline = buffered.indexOf("\n");
    const response = JSON.parse(buffered.slice(0, newline));
    buffered = buffered.slice(newline + 1);
    expect(response.id).toBe(requestID);
    expect(response.jsonrpc).toBe("2.0");
    return response;
  }
  try {
    const hello = await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "ward-test", version: "1" } });
    expect(hello.result.protocolVersion).toBe("2025-06-18");
    expect(hello.result.instructions).toContain("find_server");
    const tools = await call("tools/list");
    expect(tools.result.tools.map((tool: { name: string }) => tool.name)).toEqual(["find_server", "sudo"]);
    for (const request of [
      { name: "get_password", arguments: {} },
      { name: "find_server", arguments: { query: "" } },
      { name: "sudo", arguments: { entryID: "bad", arguments: ["id"] } },
      { name: "sudo", arguments: { entryID: "00000000-0000-0000-0000-000000000000", arguments: [] } },
    ]) {
      const response = await call("tools/call", request);
      expect(response.result.isError).toBe(true);
      expect(response.result.structuredContent).toBeUndefined();
    }
    expect((await call("ping")).result).toEqual({});
  } finally {
    await child.stdin.end();
    await child.exited;
    reader.releaseLock();
  }
}, 10_000);
