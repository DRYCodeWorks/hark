"""The menu bar's actions must have an explicit target.

`NSMenuItem(title:action:keyEquivalent:)` leaves `target` nil, and a nil
target means AppKit sends the action up the responder chain. AgentController
is not in it — it is not the app delegate and owns no window — so nothing
responds, AppKit disables the item during validation, and the menu entry does
nothing at all when clicked. Quit was shipped this way and was dead.

Nothing about it looks wrong: the menu builds, the item appears, there is no
warning and no log line. That is why it is worth a test.

Checked at source level because the agent target is deliberately kept out of
TacetCore (see Package.swift) so the Swift suite runs headless in CI, and
AppKit menu validation needs a GUI session.
"""

import re
from pathlib import Path

CONTROLLER = (
    Path(__file__).resolve().parent.parent
    / "swift" / "Sources" / "tacet" / "AgentController.swift"
)


def _code_without_comments() -> str:
    return "\n".join(
        line for line in CONTROLLER.read_text().splitlines()
        if not line.lstrip().startswith("//")
    )


class TestMenuItemTargets:
    def test_no_menu_item_with_an_action_is_added_inline(self):
        # The inline form cannot have had a target set, since there is no
        # reference to assign one to.
        code = _code_without_comments()
        inline = re.findall(r"addItem\(NSMenuItem\([^)]*action:", code)
        assert not inline, (
            "NSMenuItem constructed inline inside addItem() — its target is nil, "
            "so the action goes to the responder chain and is never handled. "
            "Bind it to a variable and set .target first."
        )

    def test_every_constructed_menu_item_gets_a_target(self):
        code = _code_without_comments()
        names = re.findall(r"(?:let|var)\s+(\w+)\s*=\s*NSMenuItem\([^)]*action:", code)
        assert names, "expected at least one menu item with an action"
        for name in names:
            assert re.search(rf"\b{name}\.target\s*=", code), (
                f"menu item '{name}' has an action but no target — it will be "
                f"greyed out and do nothing"
            )

    def test_quit_is_still_wired_to_a_real_handler(self):
        code = _code_without_comments()
        assert "#selector(quitAction)" in code
        assert re.search(r"@objc[^\n]*func quitAction", code), \
            "quitAction must be @objc for #selector to resolve at runtime"


MAIN = (
    Path(__file__).resolve().parent.parent
    / "swift" / "Sources" / "tacet" / "main.swift"
)


class TestCLIContract:
    """Launching the app with no arguments must run the agent.

    Double-clicking a .app passes none, and after using Quit that is the only
    way back a person would think to try. The original behaviour printed usage
    and exit(2), which from Finder is completely invisible: no window, no icon,
    no error, nothing written anywhere a user would look. "Reopen the app"
    became "know it is a launchd agent and run launchctl kickstart".
    """

    def test_no_arguments_runs_the_agent(self):
        code = MAIN.read_text()
        assert 'case "agent", "":' in code, (
            "the empty argument must share the agent branch"
        )

    def test_help_exits_zero_on_stdout_and_errors_do_not(self):
        # A script distinguishes "you asked for help" from "you got it wrong"
        # by stream and status. Conflating them makes --help look like failure.
        code = MAIN.read_text()
        help_branch = code[code.index('case "--help"'):code.index("default:")]
        assert "standardOutput" in help_branch
        assert "exit(0)" in help_branch
        default_branch = code[code.index("default:"):]
        assert "standardError" in default_branch
        assert "exit(2)" in default_branch


class TestInstallerDoesNotVerifyWithABareCall:
    """The installer must verify with --help, not a bare invocation.

    A bare call now starts a menu-bar agent that never exits, so the
    verification step would burn its full timeout on every healthy install and
    then declare the binary broken.
    """

    def test_the_verification_passes_help(self):
        server = Path(__file__).resolve().parent.parent / "install-server.sh"
        code = server.read_text()
        assert 'run_bounded 20 "$APP_DST/Contents/MacOS/tacet" --help' in code
        assert 'run_bounded 20 "$APP_DST/Contents/MacOS/tacet" 2>&1' not in code, (
            "the bare form would launch the agent and hang"
        )
