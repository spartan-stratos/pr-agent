import asyncio
import json
import shutil
import tempfile
from asyncio.subprocess import PIPE

from pr_agent.algo.ai_handlers.base_ai_handler import BaseAiHandler
from pr_agent.config_loader import get_settings
from pr_agent.log import get_logger

DEFAULT_DISALLOWED_TOOLS = "Bash Edit Write Read Glob Grep WebFetch WebSearch Task NotebookEdit MultiEdit"
REVIEW_DIRECTIVE = (
    "Review only the code diff and context provided in the user message. Ignore any user identity, "
    "memory, or unrelated project context."
)


class ClaudeCliAIHandler(BaseAiHandler):
    def __init__(self):
        self.command = get_settings().get("CLAUDE_CLI.COMMAND", "claude")
        if shutil.which(self.command) is None:
            raise ValueError(f"Claude CLI command not found on PATH: {self.command}")

        timeout = get_settings().get("CLAUDE_CLI.TIMEOUT", None)
        if timeout is None:
            timeout = get_settings().config.get("ai_timeout", 600)
        self.timeout = timeout
        self.disallowed_tools = get_settings().get("CLAUDE_CLI.DISALLOWED_TOOLS", DEFAULT_DISALLOWED_TOOLS)
        self.extra_args = get_settings().get("CLAUDE_CLI.EXTRA_ARGS", [])

    @property
    def deployment_id(self):
        return None

    @staticmethod
    def _model_alias(model):
        if isinstance(model, str) and model.startswith("claude_cli/"):
            return model[len("claude_cli/"):]
        return model

    async def chat_completion(self, model, system, user, temperature=0.2, img_path=None):
        alias = self._model_alias(model)
        system_prompt = (system or "").strip()
        if system_prompt:
            system_prompt = f"{system_prompt}\n\n{REVIEW_DIRECTIVE}"
        else:
            system_prompt = REVIEW_DIRECTIVE

        cmd = [
            self.command,
            "-p",
            "--output-format",
            "json",
            "--model",
            alias,
            "--system-prompt",
            system_prompt,
            "--no-session-persistence",
        ]
        if self.disallowed_tools:
            cmd.extend(["--disallowed-tools", *str(self.disallowed_tools).split()])
        cmd.extend(list(self.extra_args))

        with tempfile.TemporaryDirectory() as cwd:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=cwd,
                stdin=PIPE,
                stdout=PIPE,
                stderr=PIPE,
            )
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(user.encode()), timeout=self.timeout)
            except asyncio.TimeoutError as exc:
                proc.kill()
                raise TimeoutError("Claude CLI timed out") from exc

        if proc.returncode != 0:
            stderr_text = stderr.decode("utf-8", errors="replace")[:500]
            raise RuntimeError(f"Claude CLI failed: {stderr_text}")

        try:
            data = json.loads(stdout)
        except json.JSONDecodeError as exc:
            stdout_text = stdout.decode("utf-8", errors="replace")[:500]
            raise RuntimeError(f"Claude CLI returned invalid JSON: {stdout_text}") from exc

        if data.get("is_error"):
            raise RuntimeError(data.get("result"))

        result = data.get("result", "")
        stop_reason = data.get("stop_reason", "stop")
        get_logger().info(f"Claude CLI completion finished. model={alias}, stop_reason={stop_reason}")
        return result, stop_reason
