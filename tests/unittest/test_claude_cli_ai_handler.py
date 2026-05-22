import pytest

import pr_agent.algo.ai_handlers.claude_cli_ai_handler as claude_handler


class FakeBox:
    def __init__(self, values=None, **attrs):
        self._values = values or {}
        for key, value in attrs.items():
            setattr(self, key, value)

    def get(self, key, default=None):
        return self._values.get(key, default)


class FakeSettings:
    def __init__(self, config_values=None, settings_values=None):
        self.config = FakeBox(config_values or {}, ai_timeout=30)
        self._settings_values = settings_values or {}

    def get(self, key, default=None):
        return self._settings_values.get(key, default)


class MockProc:
    def __init__(self, returncode=0, stdout=b"", stderr=b""):
        self.returncode = returncode
        self._stdout = stdout
        self._stderr = stderr
        self.communicated = []
        self.killed = False

    async def communicate(self, stdin):
        self.communicated.append(stdin)
        return self._stdout, self._stderr

    def kill(self):
        self.killed = True


def _patch_settings(monkeypatch, config_values=None, settings_values=None):
    monkeypatch.setattr(
        claude_handler,
        "get_settings",
        lambda: FakeSettings(config_values=config_values, settings_values=settings_values),
    )


def test_model_alias():
    assert claude_handler.ClaudeCliAIHandler._model_alias("claude_cli/sonnet") == "sonnet"
    assert claude_handler.ClaudeCliAIHandler._model_alias("sonnet") == "sonnet"


@pytest.mark.asyncio
async def test_chat_completion_returns_result_and_builds_expected_argv(monkeypatch):
    _patch_settings(monkeypatch)
    monkeypatch.setattr(claude_handler.shutil, "which", lambda command: f"/usr/bin/{command}")

    calls = {}
    proc = MockProc(stdout=b'{"result":"hello","stop_reason":"end_turn","is_error":false}')

    async def fake_create_subprocess_exec(*args, **kwargs):
        calls["args"] = args
        calls["kwargs"] = kwargs
        return proc

    monkeypatch.setattr(claude_handler.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)
    handler = claude_handler.ClaudeCliAIHandler()

    result = await handler.chat_completion("claude_cli/sonnet", "system prompt", "user prompt")

    assert result == ("hello", "end_turn")
    assert proc.communicated == [b"user prompt"]
    assert "-p" in calls["args"]
    assert "--output-format" in calls["args"]
    assert "json" in calls["args"]
    assert "--model" in calls["args"]
    assert "sonnet" in calls["args"]
    assert "--no-session-persistence" in calls["args"]
    assert "--bare" not in calls["args"]
    assert calls["kwargs"]["stdin"] is claude_handler.PIPE
    assert calls["kwargs"]["stdout"] is claude_handler.PIPE
    assert calls["kwargs"]["stderr"] is claude_handler.PIPE
    assert calls["kwargs"]["cwd"]


@pytest.mark.asyncio
async def test_chat_completion_raises_on_cli_reported_error(monkeypatch):
    _patch_settings(monkeypatch)
    monkeypatch.setattr(claude_handler.shutil, "which", lambda command: f"/usr/bin/{command}")
    proc = MockProc(stdout=b'{"result":"failure","stop_reason":"stop","is_error":true}')

    async def fake_create_subprocess_exec(*args, **kwargs):
        return proc

    monkeypatch.setattr(claude_handler.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)
    handler = claude_handler.ClaudeCliAIHandler()

    with pytest.raises(RuntimeError, match="failure"):
        await handler.chat_completion("claude_cli/sonnet", "", "user prompt")


@pytest.mark.asyncio
async def test_chat_completion_raises_on_non_zero_returncode(monkeypatch):
    _patch_settings(monkeypatch)
    monkeypatch.setattr(claude_handler.shutil, "which", lambda command: f"/usr/bin/{command}")
    proc = MockProc(returncode=1, stdout=b"{}", stderr=b"bad stderr")

    async def fake_create_subprocess_exec(*args, **kwargs):
        return proc

    monkeypatch.setattr(claude_handler.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)
    handler = claude_handler.ClaudeCliAIHandler()

    with pytest.raises(RuntimeError, match="bad stderr"):
        await handler.chat_completion("claude_cli/sonnet", "", "user prompt")
