#!/usr/bin/env bun

import * as core from "@actions/core";
import { writeFile } from "fs/promises";

async function run() {
  try {
    const githubToken = process.env.GITHUB_TOKEN!;

    // Create MCP configuration file
    const mcpConfig = {
      mcpServers: {
        github: {
          command: "docker",
          args: [
            "run",
            "-i",
            "--rm",
            "-e",
            "GITHUB_PERSONAL_ACCESS_TOKEN",
            "ghcr.io/ashwin-ant/github-mcp-server:latest",
          ],
          env: {
            GITHUB_PERSONAL_ACCESS_TOKEN: githubToken,
          },
        },
      },
    };

    await writeFile("/tmp/mcp_config.json", JSON.stringify(mcpConfig, null, 2));
  } catch (error) {
    core.setFailed(`Install MCP server failed with error: ${error}`);
    process.exit(1);
  }
}

run();
