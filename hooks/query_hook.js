async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  
  const toolArgs = JSON.parse(Buffer.concat(chunks).toString());
  
  const toolName = toolArgs.tool_name || "";
  const input = toolArgs.tool_input || {};

  // Check file paths for Read/Grep
  const readPath = input.file_path || input.path || "";

  // Check command string for Bash
  const command = input.command || "";

  const blocked =
    readPath.includes('.env') || readPath.includes('secrets') ||
    (toolName === "Bash" && /\.env\b/.test(command));

  if (blocked) {
    console.error("Blocked: access to .env / secrets files is not allowed");
    process.exit(2);
  }
}

main();