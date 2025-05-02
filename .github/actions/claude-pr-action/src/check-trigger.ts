#!/usr/bin/env bun

import * as core from "@actions/core";

async function run() {
  try {
    const eventName = process.env.GITHUB_EVENT_NAME;
    const eventAction = process.env.GITHUB_EVENT_ACTION;
    const assigneeTrigger = process.env.ASSIGNEE_TRIGGER || "";
    const assigneeUsername = process.env.ASSIGNEE_USERNAME || "";
    const triggerPhrase = process.env.TRIGGER_PHRASE || "/claude";
    const issueBody = process.env.ISSUE_BODY || "";
    const commentBody = process.env.COMMENT_BODY || "";

    let containsTrigger = false;

    // Check for assignee trigger
    if (eventName === "issues" && eventAction === "assigned") {
      // Remove @ symbol from assignee_trigger if present
      let triggerUser = assigneeTrigger.replace(/^@/, "");

      if (triggerUser && assigneeUsername === triggerUser) {
        console.log(`Issue assigned to trigger user '${triggerUser}'`);
        containsTrigger = true;
      }
    }

    // Check for issue body trigger on issue creation
    if (eventName === "issues" && eventAction === "opened") {
      // Check for exact match with word boundaries
      const regex = new RegExp(
        `(^|\\s|$)${escapeRegExp(triggerPhrase)}(\\s|$)`,
      );
      if (regex.test(issueBody)) {
        console.log(
          `Issue body contains exact trigger phrase '${triggerPhrase}'`,
        );
        containsTrigger = true;
      }
    }

    // Check for comment trigger
    if (
      eventName === "issue_comment" ||
      eventName === "pull_request_review_comment"
    ) {
      // Check for exact match with word boundaries
      const regex = new RegExp(
        `(^|\\s|$)${escapeRegExp(triggerPhrase)}(\\s|$)`,
      );
      if (regex.test(commentBody)) {
        console.log(`Comment contains exact trigger phrase '${triggerPhrase}'`);
        containsTrigger = true;
      }
    }

    core.setOutput("contains_trigger", containsTrigger.toString());
  } catch (error) {
    core.setFailed(`Check trigger failed with error: ${error}`);
    process.exit(1);
  }
}

function escapeRegExp(string: string) {
  return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

run();
