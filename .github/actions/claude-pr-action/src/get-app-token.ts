#!/usr/bin/env bun

import * as core from "@actions/core";

async function run() {
  try {
    // Get OIDC token from GitHub Actions
    const requestToken = process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
    const requestUrl = process.env.ACTIONS_ID_TOKEN_REQUEST_URL;

    if (!requestToken || !requestUrl) {
      throw new Error("OIDC request token or URL not available");
    }

    const response = await fetch(
      `${requestUrl}&audience=claude-code-github-action`,
      {
        headers: {
          Authorization: `bearer ${requestToken}`,
        },
      },
    );

    const responseData = await response.json();
    const oidcToken = responseData.value;

    if (!oidcToken) {
      throw new Error("Failed to get OIDC token");
    }

    // Exchange OIDC token for app token
    const appTokenResponse = await fetch(
      "https://api.anthropic.com/api/github/github-app-token-exchange",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${oidcToken}`,
        },
      },
    );

    const appTokenData = await appTokenResponse.json();
    const appToken = appTokenData.token || appTokenData.app_token;

    if (!appToken) {
      throw new Error("Failed to get app token");
    }

    core.setOutput("APP_TOKEN", appToken);
  } catch (error) {
    core.setFailed(`Failed to get app token: ${error}`);
    process.exit(1);
  }
}

run();
