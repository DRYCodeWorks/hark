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
