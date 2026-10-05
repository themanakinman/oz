#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail
export MACOSX_DEPLOYMENT_TARGET=26.0

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/oz-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall the suite.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((OZ_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$OZ_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${OZ_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own script.
emit_db=0
DB="${TMPDIR:-/tmp}/oz-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run [slow] [-O] [index] <name> <source...> — queue the harness. `slow` dispatches it in the first
# wave; `index` claims editor flags for a harness that is compiled by hand rather than by the suite.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -target %s-apple-macos26.0 -sdk %s' \
            "$PWD" "$(uname -m)" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim every file under `Tests/`: the harness and any helper compiled beside it. A shipped
        # source stays unclaimed, because it would get this short command instead of the app's full
        # one and `.compile` is last-wins — but the app never compiles anything in `Tests/`.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Oz/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/EntryNaming.swift $L/LauncherOrder.swift
run slow -O corpus-test    $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift
run file-search-test       $L/SearchRelevance.swift \
                           Oz/Features/FileSearch/Model/*.swift
run file-search-session-test Oz/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Oz/Features/FileSearch/Model/*.swift \
                             Oz/Features/FileSearch/Service/*.swift
run menu-search-test       $L/SearchRelevance.swift \
                           Oz/Features/MenuSearch/Model/*.swift \
                           Oz/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Oz/Features/WindowSwitcher/Model/*.swift
run index file-search-performance Oz/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Oz/Features/FileSearch/Model/*.swift \
                           Oz/Features/FileSearch/Service/FileSearchService.swift
run ranking-test           $L/SearchRelevance.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Oz/Platform/AppDisplayName.swift \
                           Oz/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run apple-shortcut-test    Oz/Features/AppleShortcuts/Model/*.swift
run calc-test              Oz/Features/Calculator/Model/*.swift
run index calc-performance Oz/Features/Calculator/Model/*.swift
run calendar-test          Oz/Features/Calendar/Model/*.swift
run clipboard-test         Oz/Features/Clipboard/Model/ClipboardStore.swift \
                           Oz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Oz/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorFormat.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Oz/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-search-test  Oz/Features/Clipboard/Model/*.swift $Q
run clipboard-text-test    Oz/Features/Clipboard/Model/*.swift $Q \
                           Oz/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Oz/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Oz/Features/Clipboard/Service/ClipboardTextWorker.swift
run pasteboard-test        Oz/Platform/PasteboardFiles.swift \
                           Oz/Features/Clipboard/Model/ClipboardStore.swift \
                           Oz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorFormat.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift \
                           Oz/Features/Clipboard/Service/ClipboardManager.swift \
                           Oz/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Oz/Platform/PasteboardFiles.swift \
                           Oz/Features/Clipboard/Model/ClipboardStore.swift \
                           Oz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorFormat.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift \
                           Oz/Features/Clipboard/Service/ClipboardManager.swift
run emoji-test             Oz/Features/Emoji/Model/EmojiCatalog.swift \
                           Oz/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Oz/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Oz/Features/Emoji/Model/EmojiCatalog.swift \
                           Oz/Features/Emoji/Model/EmojiData.generated.swift \
                           Oz/Features/Emoji/Service/EmojiIndex.swift \
                           Oz/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Oz/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Oz/Features/Launcher/Model/SearchRelevance.swift \
                           Oz/Platform/AppPaths.swift Oz/Platform/Memo.swift
run index emoji-search-performance \
                           Oz/Features/Emoji/Model/EmojiCatalog.swift \
                           Oz/Features/Emoji/Model/EmojiData.generated.swift \
                           Oz/Features/Emoji/Service/EmojiIndex.swift \
                           Oz/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Oz/Features/Launcher/Model/SearchRelevance.swift \
                           Oz/Platform/AppPaths.swift Oz/Platform/Memo.swift
run palette-selection-test Oz/Features/PaletteRowIndex.swift \
                           Oz/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Features/Settings/AppAppearance.swift
run interface-size-test    Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Features/Settings/InterfaceSize.swift \
                           Oz/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Features/Settings/InterfaceSize.swift \
                           Oz/Palette/PalettePlacement.swift
run scroll-reveal-test     Oz/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Oz/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Oz/DesignSystem/Interaction/KeyboardFocus.swift
run ai-instructions-test   Oz/Features/AI/Model/AIInstructions.swift \
                           Oz/Features/AI/Model/AIPreamble.swift
run hover-arming-test      Oz/Palette/HoverArming.swift \
                           Oz/Palette/PaletteState.swift \
                           Oz/Palette/PaletteMode.swift \
                           Oz/Features/Emoji/Model/EmojiCatalog.swift \
                           Oz/Features/Clipboard/Model/ClipboardStore.swift \
                           Oz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Oz/Features/FileSearch/Model/FileSearchFilter.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorFormat.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/CustomCommands/Model/CustomCommand.swift
run palette-escape-test    Oz/Palette/PaletteMode.swift \
                           Oz/Palette/PaletteEscapeAction.swift \
                           Oz/Palette/CommandEscapeTap.swift \
                           Oz/Features/Settings/EscapeKeyBehavior.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Oz/Palette/PaletteState.swift \
                           Oz/Palette/PaletteMode.swift \
                           Oz/Palette/HoverArming.swift \
                           Oz/Features/Emoji/Model/EmojiCatalog.swift \
                           Oz/Features/Clipboard/Model/ClipboardStore.swift \
                           Oz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Oz/Features/FileSearch/Model/FileSearchFilter.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorFormat.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Oz/Palette/PaletteMode.swift \
                           Oz/Palette/PaletteFilterAction.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Oz/Palette/ActionMenuSearchQuery.swift \
                            Oz/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Oz/Palette/PaletteShortcut.swift
run palette-tab-test       Oz/Palette/PaletteMode.swift \
                           Oz/Palette/PaletteTabAction.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Oz/Features/Launcher/Model/Fallback.swift \
                           Oz/Features/Launcher/Model/CommandID.swift \
                           Oz/Features/HotKeys/Model/HotKeyAction.swift \
                           Oz/Features/QuickActions/Model/QuickAction.swift \
                           Oz/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Oz/Features/QuickActions/Model/CustomQuickAction.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/SystemActions/Model/SystemAction.swift \
                           Oz/Features/WindowManagement/Model/WindowCommand.swift
run dictionary-test        Oz/Features/Dictionary/Model/DictionaryEntry.swift \
                           Oz/Features/Dictionary/Model/DictionaryMarkup.swift
run hotkey-test            Oz/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Oz/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Oz/Features/HotKeys/Model/HyperKey.swift \
                           Oz/Platform/ASCIIKeyboardLayout.swift \
                           Oz/Features/HotKeys/Service/KeyShortcut.swift \
                           Oz/Features/HotKeys/Model/HotKeyAction.swift \
                           Oz/Features/QuickActions/Model/QuickAction.swift \
                           Oz/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Oz/Features/QuickActions/Model/CustomQuickAction.swift \
                           Oz/Features/Launcher/Model/CommandID.swift \
                           Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/SystemActions/Model/SystemAction.swift \
                           Oz/Features/WindowManagement/Model/WindowCommand.swift
run callout-test           Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Oz/Platform/Appearance.swift \
                           Oz/Platform/Images/IconCache.swift
run entry-icon-test        Oz/Platform/Appearance.swift \
                           Oz/Platform/Images/IconCache.swift \
                           Oz/Platform/Images/FileIconStamp.swift
run ext-icon-test          Oz/Platform/Appearance.swift \
                           Oz/Platform/AppDisplayName.swift \
                           Oz/Platform/Images/IconCache.swift \
                           Oz/Platform/Compression/Zlib.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Oz/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Oz/Features/Extensions/Model/ExtensionManifest.swift \
                           Oz/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Oz/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Oz/Features/Extensions/Model/RenderNode.swift \
                           Oz/Features/Extensions/Service/ExtensionCatalog.swift \
                           Oz/Features/Extensions/Service/ExtensionFetcher.swift \
                           Oz/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Oz/Features/Extensions/Service/ExtensionOAuthKeychain.swift \
                           Oz/Features/Extensions/Service/ExtensionOAuthSession.swift \
                           Oz/Features/Extensions/Service/ExtensionRuntime.swift \
                           Oz/Features/Extensions/Service/ExtensionIconCache.swift \
                           Oz/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Oz/Features/Extensions/UI/ExtensionImage.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift
run system-action-test     Oz/Features/SystemActions/Model/SystemAction.swift
run volume-test            Oz/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Oz/Features/WindowManagement/Model/WindowCommand.swift \
                           Oz/Features/WindowManagement/Model/WindowCycle.swift \
                           Oz/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Oz/Features/WindowManagement/Model/WindowActionMemory.swift
run space-gesture-test     Oz/Features/WindowManagement/Model/WindowCommand.swift \
                           Oz/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Oz/Features/WindowManagement/Model/WindowCommand.swift \
                           Oz/Features/WindowManagement/Model/WindowCycle.swift \
                           Oz/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Oz/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Oz/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Oz/Features/WindowManagement/Model/WindowLayout.swift \
                           Oz/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Oz/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Oz/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Oz/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Oz/Features/WindowManagement/Model/CustomWindowSizeStore.swift
run custom-command-test    Oz/Platform/PseudoTerminal.swift \
                           Oz/Features/CustomCommands/Model/CustomCommand.swift \
                           Oz/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Oz/Features/CustomCommands/Service/ShellCommandRunner.swift
run uninstall-test         Oz/Features/Uninstall/Model/UninstallTarget.swift \
                           Oz/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Oz/Features/Uninstall/Model/UninstallRules.swift \
                           Oz/Features/Uninstall/Model/UninstallProtection.swift \
                           Oz/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Oz/Features/Quicklinks/Model/Quicklink.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Oz/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Oz/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run slow snippets-test     Oz/Platform/NotificationToken.swift \
                           Oz/Platform/HealthTicker.swift \
                           Oz/Platform/AccessibilityText.swift \
                           Oz/Features/Snippets/Model/*.swift \
                           Oz/Features/Snippets/Service/*.swift \
                           Oz/Features/TextInjection/Service/*.swift
run notes-test             Oz/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Oz/Features/Notes/Model/*.swift \
                           Oz/Features/Notes/Service/*.swift
run notes-editor-test      Oz/Platform/Signposts.swift \
                           Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Platform/NotificationToken.swift \
                           Oz/Features/TextInjection/Service/InjectableTextView.swift \
                           Oz/Features/Notes/Model/NoteDocument.swift \
                           Oz/Features/Notes/Model/NoteMarkdown.swift \
                           Oz/Features/Notes/Model/NoteMarkdownParser.swift \
                           Oz/Features/Notes/Model/NoteInlineScanner.swift \
                           Oz/Features/Notes/Model/NoteEditPlan.swift \
                           Oz/Features/Notes/Model/NoteEditAction.swift \
                           Oz/Features/Notes/Model/NoteFormatting.swift \
                           Oz/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Oz/Features/Notes/Model/NoteRevealPolicy.swift \
                           Oz/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Oz/Features/Notes/UI/NoteBlockDecoration.swift \
                           Oz/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Oz/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Oz/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Oz/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Oz/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Oz/Features/Notes/UI/NoteTextViewEditing.swift \
                           Oz/Features/Notes/UI/NoteTextView.swift \
                           Oz/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Oz/Platform/Signposts.swift \
                           Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Platform/NotificationToken.swift \
                           Oz/Features/TextInjection/Service/InjectableTextView.swift \
                           Oz/Features/Notes/Model/NoteDocument.swift \
                           Oz/Features/Notes/Model/NoteMarkdown.swift \
                           Oz/Features/Notes/Model/NoteMarkdownParser.swift \
                           Oz/Features/Notes/Model/NoteInlineScanner.swift \
                           Oz/Features/Notes/Model/NoteEditPlan.swift \
                           Oz/Features/Notes/Model/NoteEditAction.swift \
                           Oz/Features/Notes/Model/NoteFormatting.swift \
                           Oz/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Oz/Features/Notes/Model/NoteRevealPolicy.swift \
                           Oz/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Oz/Features/Notes/UI/NoteBlockDecoration.swift \
                           Oz/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Oz/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Oz/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Oz/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Oz/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Oz/Features/Notes/UI/NoteTextViewEditing.swift \
                           Oz/Features/Notes/UI/NoteTextView.swift \
                           Oz/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Oz/Features/Backup/Model/RaycastImportError.swift \
                           Oz/Features/Backup/Service/RaycastDecoder.swift \
                           Oz/Features/Backup/Service/Scrypt.swift \
                           Oz/Platform/Compression/Zlib.swift
run settings-backup-test   Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/Backup/Model/SettingsBackupCoverage.swift
run backup-archive-test    Oz/Platform/AppPaths.swift \
                           Oz/Features/Backup/Model/BackupArchive.swift \
                           Oz/Features/Backup/Model/BackupBundle.swift \
                           Oz/Features/Backup/Model/BackupCategory.swift \
                           Oz/Features/Backup/Model/BackupClipboardItem.swift \
                           Oz/Features/Backup/Model/BackupManifest.swift \
                           Oz/Features/Backup/Service/BackupStaging.swift
E=Oz/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Oz/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Oz/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-store-test         $E/Model/ExtensionRegistry.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Tests/ext-menu-bar-test.swift \
                           Tests/ext-fetch-test.swift \
                           $E/Model/ExtensionLaunchError.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionStorage.swift \
                           $E/Service/ExtensionMenuBarManager.swift \
                           $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift \
                           $E/UI/ExtensionMenuBarController.swift \
                           $E/UI/ExtensionMenuBarImage.swift \
                           Oz/Platform/Appearance.swift \
                           Oz/Platform/AppDisplayName.swift \
                           Oz/Platform/Images/IconCache.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Oz/Platform/Compression/Zlib.swift \
                           Oz/Features/Clipboard/Model/ColorValue.swift \
                           Oz/Features/Clipboard/Model/ColorSpaces.swift
run settings-history-test  Oz/Features/Settings/SettingsTab.swift \
                           Oz/Features/Settings/SettingsHistory.swift \
                           Oz/Features/Settings/SettingsAnchor.swift \
                           Oz/Features/Settings/SettingsNavigationState.swift \
                           Oz/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift
run updates-test           Oz/Features/Updates/Model/*.swift \
                           Oz/Features/Updates/Service/BundleSignature.swift
run support-test           Oz/Features/Support/Model/*.swift
run ai-provider-test       Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/AI/Model/*.swift \
                           Oz/Features/AI/Settings/AISettingsStore.swift
run ai-pdf-test            Oz/Features/AI/Model/AIPDFText.swift \
                           Oz/Features/AI/Model/AIRequest.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/AI/Model/AIAttachmentPolicy.swift \
                           Oz/Features/AI/Service/AIProvider.swift \
                           Oz/Features/AI/Service/AIPDFTextExtractor.swift \
                           Oz/Features/AI/Service/AIPDFTextReader.swift \
                           Oz/Features/AI/Service/AIPDFTextProvider.swift
run slow ai-command-test   Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/AIFileTools.swift \
                           Oz/Features/AI/Model/AIFileAccessPolicy.swift \
                           Oz/Features/AI/Model/AICommandPolicy.swift \
                           Oz/Features/AI/Service/AIFileToolRunner.swift \
                           Oz/Features/AI/Service/AICommandRunner.swift
run ai-chat-test           Oz/Features/AI/Model/AIRequest.swift \
                           Oz/Features/AI/Model/AIFileTools.swift \
                           Oz/Features/AI/Model/AIConnection.swift \
                           Oz/Features/AI/Model/AppleIntelligence.swift \
                           Oz/Features/AI/Model/AIAttachmentPolicy.swift \
                           Oz/Features/AI/Model/AIRetention.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/AI/Model/ChatMessage.swift \
                           Oz/Features/AI/Model/ChatSession.swift \
                           Oz/Features/AI/Model/ChatChoices.swift \
                           Oz/Features/AI/Model/ChatReferences.swift \
                           Oz/Features/AI/Model/ChatTitle.swift \
                           Oz/Features/AI/Model/ChatFind.swift \
                           Oz/Features/AI/Model/ChatCitations.swift \
                           Oz/Features/AI/Model/ChatToolScope.swift \
                           Oz/Features/AI/Model/MarkdownBlock.swift \
                           Oz/Features/AI/Service/AIProvider.swift \
                           Oz/Features/AI/Service/ChatHistoryStore.swift \
                           Oz/Features/AI/Service/AIToolLoopProvider.swift \
                           Oz/Features/AI/UI/AIChatState.swift \
                           Oz/Features/AI/UI/AIChatSurfacesState.swift \
                           Oz/Features/AI/UI/ChatFindState.swift
run chat-markdown-test     Oz/Platform/Appearance.swift \
                           Oz/DesignSystem/Theme.swift \
                           Oz/DesignSystem/InterfaceMetrics.swift \
                           Oz/Features/Settings/InterfaceSize.swift \
                           Oz/Features/AI/Model/AIRequest.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/AI/Model/ChatMessage.swift \
                           Oz/Features/AI/Model/ChatChoices.swift \
                           Oz/Features/AI/Model/ChatReferences.swift \
                           Oz/Features/AI/Model/ChatCitations.swift \
                           Oz/Features/AI/Model/ChatFind.swift \
                           Oz/Features/AI/Model/MarkdownBlock.swift \
                           Oz/Features/AI/UI/ChatTextHighlight.swift \
                           Oz/Features/AI/UI/ChatMarkdownRenderer.swift
run mcp-test               Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/AI/Model/AIConnection.swift \
                           Oz/Features/AI/Model/AppleIntelligence.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/AIToolServer.swift \
                           Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/MCP/Model/*.swift \
                           Oz/Features/MCP/Settings/MCPSettingsStore.swift
run -O text-diff-test      Oz/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Oz/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/AI/Model/AIConnection.swift \
                           Oz/Features/AI/Model/AppleIntelligence.swift \
                           Oz/Features/AI/Model/ChatGPTSubscription.swift \
                           Oz/Features/AI/Model/InstalledAI.swift \
                           Oz/Features/QuickActions/Model/*.swift \
                           Oz/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/AI/Model/*.swift \
                           Oz/Features/AI/Service/AIProvider.swift \
                           Oz/Features/AI/Service/AppleIntelligenceProvider.swift
run mcp-oauth-test         Oz/Platform/ExecutableLocator.swift \
                           Oz/Platform/KeychainSecretStore.swift \
                           Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/AI/Model/AIConnection.swift \
                           Oz/Features/AI/Model/AppleIntelligence.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/AIToolServer.swift \
                           Oz/Features/AI/Model/AIStreamDecoder.swift \
                           Oz/Features/AI/Model/AIRequest.swift \
                           Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/MCP/Model/*.swift \
                           Oz/Features/MCP/Service/*.swift
run slow mcp-stdio-test    Oz/Platform/ExecutableLocator.swift \
                           Oz/Platform/KeychainSecretStore.swift \
                           Oz/Features/Settings/AppSettingsKey.swift \
                           Oz/Features/AI/Model/AIConnection.swift \
                           Oz/Features/AI/Model/AppleIntelligence.swift \
                           Oz/Features/AI/Model/AITool.swift \
                           Oz/Features/AI/Model/AIToolServer.swift \
                           Oz/Features/AI/Model/AIStreamDecoder.swift \
                           Oz/Features/AI/Model/AIRequest.swift \
                           Oz/Features/AI/Model/JSONValue.swift \
                           Oz/Features/MCP/Model/*.swift \
                           Oz/Features/MCP/Service/*.swift
run slow codex-turn-test   Oz/Platform/AppPaths.swift \
                           Oz/Features/AI/Model/*.swift \
                           Oz/Features/AI/Service/AIProvider.swift \
                           Oz/Features/AI/Service/ChatGPTSubscriptionManager.swift \
                           Oz/Features/AI/Service/CodexAppServerClient.swift \
                           Oz/Features/AI/Service/InstalledAIProbe.swift \
                           Oz/Platform/ExecutableLocator.swift \
                           Oz/Features/AI/Service/CodexTurnRunner.swift
run installed-ai-test     Oz/Features/AI/Model/*.swift \
                          Oz/Features/AI/Service/AIProvider.swift \
                          Oz/Platform/AppPaths.swift \
                          Oz/Platform/ExecutableLocator.swift \
                          Oz/Features/AI/Service/InstalledCLIProvider.swift \
                          Oz/Features/AI/Service/InstalledAIProbe.swift \
                          Oz/Features/AI/Service/InstalledAIManager.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${OZ_TEST_JOBS:-$(sysctl -n hw.ncpu)}"
export OZ_TEST_TIMEOUT="${OZ_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
