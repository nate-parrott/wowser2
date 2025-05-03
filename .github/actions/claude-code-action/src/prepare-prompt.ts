#!/usr/bin/env bun

import * as core from "@actions/core";
import { writeFile, mkdir } from "fs/promises";
import { existsSync, statSync } from "fs";
import path from "path";

async function run() {
  try {
    // Get inputs
    const prompt = process.env.INPUT_PROMPT || "";
    const promptFile = process.env.INPUT_PROMPT_FILE || "";

    // Check if either prompt or prompt_file is provided
    if (!prompt && !promptFile) {
      core.setFailed(
        "Neither 'prompt' nor 'prompt_file' was provided. At least one is required.",
      );
      process.exit(1);
    }

    let promptPath: string;

    // Determine which prompt source to use
    if (promptFile) {
      // Check if the prompt file exists
      if (!existsSync(promptFile)) {
        core.setFailed(`Prompt file '${promptFile}' does not exist.`);
        process.exit(1);
      }

      // Use the provided prompt file
      promptPath = promptFile;
    } else {
      // Create temporary directory and file
      await mkdir("/tmp/claude-action", { recursive: true });
      promptPath = "/tmp/claude-action/prompt.txt";
      await writeFile(promptPath, prompt);
    }

    // Verify the prompt file is not empty
    const stats = statSync(promptPath);
    if (stats.size === 0) {
      core.setFailed("Prompt is empty. Please provide a non-empty prompt.");
      process.exit(1);
    }

    // Save the prompt path for the next step
    core.exportVariable("PROMPT_PATH", promptPath);
  } catch (error) {
    core.setFailed(`Action failed with error: ${error}`);
    process.exit(1);
  }
}

run();
