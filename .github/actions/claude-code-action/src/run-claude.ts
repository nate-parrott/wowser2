#!/usr/bin/env bun

import * as core from "@actions/core";
import { exec } from "child_process";
import { promisify } from "util";
import { unlink, writeFile, readFile, stat } from "fs/promises";
import { createWriteStream } from "fs";
import { spawn } from "child_process";

const execAsync = promisify(exec);

async function run() {
  try {
    // Get inputs
    const anthropicModel = process.env.INPUT_ANTHROPIC_MODEL;
    const timeoutMinutes = parseInt(process.env.INPUT_TIMEOUT_MINUTES || "10");
    const outputFile = process.env.INPUT_OUTPUT_FILE;
    const allowedTools = process.env.INPUT_ALLOWED_TOOLS;
    const disallowedTools = process.env.INPUT_DISALLOWED_TOOLS;
    const maxTurns = process.env.INPUT_MAX_TURNS;
    const mcpConfig = process.env.INPUT_MCP_CONFIG;
    const promptPath = process.env.PROMPT_PATH;

    // Set environment variables
    if (anthropicModel) {
      process.env.ANTHROPIC_MODEL = anthropicModel;
    }

    // Set timeout
    const timeoutSeconds = timeoutMinutes * 60;

    // Create a named pipe
    const pipePath = "/tmp/claude_prompt_pipe";
    try {
      await unlink(pipePath);
    } catch (e) {
      // Ignore if file doesn't exist
    }

    // Create the named pipe
    await execAsync(`mkfifo "${pipePath}"`);

    // Log prompt file size
    let promptSize = "unknown";
    try {
      const stats = await stat(promptPath!);
      promptSize = stats.size.toString();
    } catch (e) {
      // Ignore error
    }
    console.log(`Prompt file size: ${promptSize} bytes`);

    // Build Claude command
    const claudeArgs = ["-p", "--verbose", "--output-format", "stream-json"];

    if (allowedTools) {
      claudeArgs.push("--allowedTools", allowedTools);
    }
    if (disallowedTools) {
      claudeArgs.push("--disallowedTools", disallowedTools);
    }
    if (maxTurns) {
      claudeArgs.push("--max-turns", maxTurns);
    }
    if (mcpConfig) {
      claudeArgs.push("--mcp-config", mcpConfig);
    }

    // Run Claude with proper handling
    if (!outputFile) {
      // Output to console
      console.log(`Running Claude with prompt from file: ${promptPath}`);

      // Start sending prompt to pipe in background
      const catProcess = spawn("cat", [promptPath!], {
        stdio: ["ignore", "pipe", "inherit"],
      });
      catProcess.stdout.pipe(createWriteStream(pipePath));

      // Run Claude with timeout
      const claudeProcess = spawn(
        "timeout",
        [timeoutSeconds.toString(), "claude", ...claudeArgs],
        {
          stdio: ["pipe", "inherit", "inherit"],
        },
      );

      // Pipe from named pipe to Claude
      const pipeProcess = spawn("cat", [pipePath]);
      pipeProcess.stdout.pipe(claudeProcess.stdin);

      // Wait for Claude to finish
      const exitCode = await new Promise<number>((resolve) => {
        claudeProcess.on("close", (code) => {
          resolve(code || 0);
        });
      });

      // Clean up
      await unlink(pipePath);

      if (exitCode !== 0) {
        process.exit(exitCode);
      }
    } else {
      // Output to file
      console.log(
        `Running Claude with prompt from file: ${promptPath}, saving output to ${outputFile}`,
      );

      // Start sending prompt to pipe in background
      const catProcess = spawn("cat", [promptPath!], {
        stdio: ["ignore", "pipe", "inherit"],
      });
      catProcess.stdout.pipe(createWriteStream(pipePath));

      // Run Claude with timeout and tee
      const claudeProcess = spawn(
        "timeout",
        [timeoutSeconds.toString(), "claude", ...claudeArgs],
        {
          stdio: ["pipe", "pipe", "inherit"],
        },
      );

      // Pipe from named pipe to Claude
      const pipeProcess = spawn("cat", [pipePath]);
      pipeProcess.stdout.pipe(claudeProcess.stdin);

      // Tee output to console and file
      let output = "";
      claudeProcess.stdout.on("data", (data) => {
        const text = data.toString();
        process.stdout.write(text);
        output += text;
      });

      // Wait for Claude to finish
      const exitCode = await new Promise<number>((resolve) => {
        claudeProcess.on("close", (code) => {
          resolve(code || 0);
        });
      });

      // Clean up pipe
      await unlink(pipePath);

      // Process output if successful
      if (exitCode === 0) {
        await writeFile("output.txt", output);

        try {
          // Process output.txt into JSON
          const { stdout: jsonOutput } = await execAsync(
            "jq -s '.' output.txt",
          );
          await writeFile("output.json", jsonOutput);

          // Extract the result from the last item
          const { stdout: result } = await execAsync(
            "jq -r '.[-1].result' output.json",
          );
          await writeFile(outputFile, result);

          console.log(
            `Complete output saved to output.json, final response saved to ${outputFile}`,
          );
        } catch (e) {
          core.warning(`Failed to process output: ${e}`);
        }
      } else {
        console.error(`Claude failed with exit code: ${exitCode}`);
        if (exitCode === 124 || exitCode === 137) {
          console.error(
            `Claude execution timed out after ${timeoutMinutes} minutes`,
          );
        }
        process.exit(exitCode);
      }
    }
  } catch (error) {
    core.setFailed(`Action failed with error: ${error}`);
    process.exit(1);
  }
}

run();
