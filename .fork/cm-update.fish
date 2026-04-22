function cm-update --description "Sync claude-mem from this fork's release-local branch to the local plugin marketplace"
    # ── Configuration ─────────────────────────────────────────────
    # Path to the local clone of audichuang/claude-mem.
    # Override with: set -Ux CM_FORK_PATH /path/to/your/clone
    set -q CM_FORK_PATH; or set CM_FORK_PATH $HOME/GoogleDrive/research/claude-mem

    set -l marketplace $HOME/.claude/plugins/marketplaces/thedotmack
    set -l worker $marketplace/plugin/scripts/worker-service.cjs
    set -l state_file $HOME/.claude-mem/.installed-release-sha

    # ── Argument parsing ──────────────────────────────────────────
    set -l mode update
    set -l target_tag ""

    for arg in $argv
        switch $arg
            case --check
                set mode check
            case --status
                set mode status
            case --rollback
                set mode rollback
            case '--version=*'
                set mode version
                set target_tag (string replace -- '--version=' '' $arg)
            case --version
                set mode version
                # Read next positional arg
                set -l idx (contains -i -- $arg $argv)
                set target_tag $argv[(math $idx + 1)]
            case -h --help
                _cm_update_help
                return 0
            case '*'
                # skip positional (consumed by --version)
        end
    end

    # ── Preflight ─────────────────────────────────────────────────
    if not test -d "$CM_FORK_PATH/.git"
        echo "❌ Fork clone not found at: $CM_FORK_PATH"
        echo "   Set CM_FORK_PATH env var to the path of your audichuang/claude-mem clone."
        return 1
    end

    if not test -f "$worker"
        echo "❌ claude-mem plugin not installed at: $marketplace"
        echo "   Bootstrap once with: npx claude-mem@latest install"
        return 1
    end

    pushd $CM_FORK_PATH >/dev/null

    # ── Status mode ───────────────────────────────────────────────
    if test "$mode" = status
        _cm_update_status $state_file
        popd >/dev/null
        return 0
    end

    # ── Fetch ─────────────────────────────────────────────────────
    echo "📡 Fetching origin..."
    if not git fetch origin release-local --tags 2>/dev/null
        echo "⚠️  release-local not on origin yet."
        echo "   The GitHub Action hasn't produced a release yet. Trigger it at:"
        echo "   https://github.com/audichuang/claude-mem/actions/workflows/sync-upstream.yml"
        popd >/dev/null
        return 1
    end

    # ── Resolve target ref ────────────────────────────────────────
    set -l target_ref
    set -l target_label
    switch $mode
        case version
            if test -z "$target_tag"
                echo "❌ --version requires a tag (e.g. my-release/v12.3.8-20260422)"
                popd >/dev/null
                return 1
            end
            if not git rev-parse --verify "refs/tags/$target_tag" >/dev/null 2>&1
                echo "❌ Tag not found: $target_tag"
                echo "   Available rollback tags:"
                git tag --list 'my-release/*' --sort=-refname | head -10 | sed 's/^/     /'
                popd >/dev/null
                return 1
            end
            set target_ref $target_tag
            set target_label "tag $target_tag"
        case rollback
            # Pick the 2nd newest my-release tag
            set -l tags (git tag --list 'my-release/*' --sort=-v:refname)
            if test (count $tags) -lt 2
                echo "❌ Not enough my-release tags to roll back (need ≥2)"
                popd >/dev/null
                return 1
            end
            set target_ref $tags[2]
            set target_label "rollback to $tags[2]"
        case '*'
            set target_ref origin/release-local
            set target_label "latest release-local"
    end

    set -l target_sha (git rev-parse "$target_ref")
    set -l installed ""
    test -f "$state_file"; and set installed (cat "$state_file")

    # ── Check mode: report and exit ───────────────────────────────
    if test "$mode" = check
        if test "$target_sha" = "$installed"
            echo "✅ Already on $target_label ("(string sub -l 8 -- $target_sha)")"
        else
            echo "📦 Update available"
            echo "   installed: $installed"
            echo "   target:    $target_sha ($target_label)"
        end
        popd >/dev/null
        return 0
    end

    # ── Skip if nothing to do ─────────────────────────────────────
    if test "$target_sha" = "$installed"; and test "$mode" = update
        echo "✅ Already on $target_label ("(string sub -l 8 -- $target_sha)")"
        popd >/dev/null
        return 0
    end

    # ── Apply ─────────────────────────────────────────────────────
    echo "🔄 Checking out $target_label..."
    git checkout release-local 2>/dev/null
    or git checkout -b release-local origin/release-local
    git reset --hard $target_ref >/dev/null

    echo "📦 Syncing to marketplace ($marketplace)..."
    if not npm run sync-marketplace 2>&1 | tail -4
        echo "❌ sync-marketplace failed"
        popd >/dev/null
        return 1
    end

    echo "🔄 Restarting worker..."
    bun "$worker" restart 2>&1 | tail -2

    # Record what we installed
    echo $target_sha > "$state_file"

    # Summary
    set -l tag_match (git describe --tags --exact-match $target_ref 2>/dev/null)
    test -z "$tag_match"; and set tag_match "(no tag)"
    echo ""
    echo "✅ claude-mem updated"
    echo "   ref:  $target_label"
    echo "   sha:  "(string sub -l 12 -- $target_sha)
    echo "   tag:  $tag_match"
    echo ""
    echo "   Next Claude Code / Codex / Gemini session will pick up new bundle."

    popd >/dev/null
end

# ── Helpers ──────────────────────────────────────────────────────

function _cm_update_help
    echo "cm-update — sync claude-mem from your fork's release-local"
    echo ""
    echo "Usage:"
    echo "  cm-update                          Pull latest release-local and install"
    echo "  cm-update --check                  Check if update available (no install)"
    echo "  cm-update --status                 Show installed / latest / recent tags"
    echo "  cm-update --version <tag>          Install a specific my-release/* tag"
    echo "  cm-update --rollback               Install the 2nd-newest my-release tag"
    echo "  cm-update -h | --help              Show this help"
    echo ""
    echo "Environment:"
    echo "  CM_FORK_PATH  Path to your claude-mem fork clone"
    echo "                (default: ~/GoogleDrive/research/claude-mem)"
end

function _cm_update_status --argument-names state_file
    set -l current_sha (git rev-parse --short HEAD 2>/dev/null; or echo unknown)
    set -l current_branch (git rev-parse --abbrev-ref HEAD 2>/dev/null; or echo "(detached)")
    set -l remote_sha (git rev-parse --short origin/release-local 2>/dev/null; or echo "(not yet)")
    set -l installed "(none)"
    test -f "$state_file"; and set installed (cat "$state_file" | cut -c1-12)

    echo "Local checkout:"
    echo "  branch:  $current_branch"
    echo "  HEAD:    $current_sha"
    echo ""
    echo "Remote:"
    echo "  release-local: $remote_sha"
    echo ""
    echo "Installed in marketplace:"
    echo "  sha:  $installed"
    echo ""
    echo "Recent rollback tags:"
    set -l tags (git tag --list 'my-release/*' --sort=-v:refname | head -5)
    if test (count $tags) -eq 0
        echo "  (none — GitHub Action hasn't produced any yet)"
    else
        for t in $tags
            echo "  $t"
        end
    end
end
