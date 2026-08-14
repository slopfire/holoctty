const std = @import("std");
const builtin = @import("builtin");

const global = @import("../../global.zig");

pub const default_icon: [:0]const u8 = "utilities-terminal-symbolic";
pub const remote_icon: [:0]const u8 = "holoctty-cli-remote-server-symbolic";

pub const ProcessState = struct {
    icon: [:0]const u8 = default_icon,
    remote: bool = false,
    interactive_shell: bool = false,
    host: [256]u8 = undefined,
    host_len: usize = 0,

    pub fn remoteHost(self: *const ProcessState) ?[]const u8 {
        return if (self.host_len > 0) self.host[0..self.host_len] else null;
    }
};

pub fn processName(icon: []const u8) [:0]const u8 {
    const mappings = [_]struct {
        icon: []const u8,
        name: [:0]const u8,
    }{
        .{ .icon = "holoctty-cli-agent-codex-symbolic", .name = "Codex" },
        .{ .icon = "holoctty-cli-agent-claude-symbolic", .name = "Claude" },
        .{ .icon = "holoctty-cli-agent-gemini-symbolic", .name = "Gemini" },
        .{ .icon = "holoctty-cli-agent-opencode-symbolic", .name = "OpenCode" },
        .{ .icon = "holoctty-cli-agent-grok-symbolic", .name = "Grok" },
        .{ .icon = "holoctty-cli-agent-cursor-symbolic", .name = "Cursor" },
        .{ .icon = "holoctty-cli-agent-copilot-symbolic", .name = "Copilot" },
        .{ .icon = "holoctty-cli-agent-amp-symbolic", .name = "Amp" },
        .{ .icon = "holoctty-cli-agent-pi-symbolic", .name = "Pi" },
        .{ .icon = "holoctty-cli-agent-omp-symbolic", .name = "OMP" },
        .{ .icon = "holoctty-cli-agent-devin-symbolic", .name = "Devin" },
        .{ .icon = "holoctty-cli-agent-aider-symbolic", .name = "Aider" },
        .{ .icon = "holoctty-cli-agent-goose-symbolic", .name = "Goose" },
        .{ .icon = "holoctty-cli-agent-crush-symbolic", .name = "Crush" },
        .{ .icon = "holoctty-cli-agent-cline-symbolic", .name = "Cline" },
        .{ .icon = "holoctty-cli-agent-droid-symbolic", .name = "Droid" },
        .{ .icon = "holoctty-cli-agent-kilo-symbolic", .name = "Kilo" },
        .{ .icon = "holoctty-cli-agent-kimi-symbolic", .name = "Kimi" },
        .{ .icon = "holoctty-cli-agent-qwen-symbolic", .name = "Qwen" },
        .{ .icon = "holoctty-cli-agent-auggie-symbolic", .name = "Auggie" },
        .{ .icon = "holoctty-cli-agent-hermes-symbolic", .name = "Hermes" },
        .{ .icon = "holoctty-cli-agent-plandex-symbolic", .name = "Plandex" },
        .{ .icon = "holoctty-cli-agent-openhands-symbolic", .name = "OpenHands" },
        .{ .icon = "holoctty-cli-agent-continue-symbolic", .name = "Continue" },
        .{ .icon = "holoctty-cli-agent-amazonq-symbolic", .name = "Amazon Q" },
        .{ .icon = "holoctty-cli-shell-bash-symbolic", .name = "Bash" },
        .{ .icon = "holoctty-cli-shell-zsh-symbolic", .name = "Zsh" },
        .{ .icon = "holoctty-cli-shell-fish-symbolic", .name = "Fish" },
        .{ .icon = "holoctty-cli-shell-nushell-symbolic", .name = "Nushell" },
        .{ .icon = "holoctty-cli-shell-powershell-symbolic", .name = "PowerShell" },
        .{ .icon = "holoctty-cli-tui-lazygit-symbolic", .name = "Lazygit" },
        .{ .icon = "holoctty-cli-tui-gitui-symbolic", .name = "GitUI" },
        .{ .icon = "holoctty-cli-tui-lazydocker-symbolic", .name = "Lazydocker" },
        .{ .icon = "holoctty-cli-tui-docker-symbolic", .name = "Docker" },
        .{ .icon = "holoctty-cli-tui-btop-symbolic", .name = "System Monitor" },
        .{ .icon = "holoctty-cli-tui-k8s-symbolic", .name = "Kubernetes" },
        .{ .icon = "holoctty-cli-tui-nvim-symbolic", .name = "Neovim" },
        .{ .icon = "holoctty-cli-tui-vim-symbolic", .name = "Vim" },
        .{ .icon = "holoctty-cli-tui-helix-symbolic", .name = "Helix" },
        .{ .icon = "holoctty-cli-tui-yazi-symbolic", .name = "Yazi" },
        .{ .icon = "holoctty-cli-tui-ranger-symbolic", .name = "Ranger" },
        .{ .icon = "holoctty-cli-tui-glow-symbolic", .name = "Glow" },
        .{ .icon = "holoctty-cli-tui-superfile-symbolic", .name = "Superfile" },
        .{ .icon = "holoctty-cli-tui-tig-symbolic", .name = "Tig" },
        .{ .icon = remote_icon, .name = "Remote Session" },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, icon, mapping.icon)) return mapping.name;
    }
    return "Terminal";
}

pub fn isShellIcon(icon: []const u8) bool {
    return std.mem.startsWith(u8, icon, "holoctty-cli-shell-");
}

pub fn isTuiIcon(icon: []const u8) bool {
    return std.mem.startsWith(u8, icon, "holoctty-cli-tui-");
}

/// True if `icon` is one of the processes listed in
/// `window-padding-extend-full-ignore`. Names match a command (`omp`),
/// a known alias (`oh-my-pi`), or the session-bar display name (`OMP`).
pub fn ignoreMatches(icon: []const u8, names: anytype) bool {
    for (names) |raw| {
        const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (name.len == 0) continue;
        if (iconForCommand(name)) |mapped| {
            if (std.mem.eql(u8, mapped, icon)) return true;
        }
        if (std.ascii.eqlIgnoreCase(processName(icon), name)) return true;
        if (std.ascii.eqlIgnoreCase(icon, name)) return true;
    }
    return false;
}

/// True if the PTY foreground process (or the child the session bar
/// would show) matches `window-padding-extend-full-ignore`.
pub fn processIgnored(pid: u64, names: anytype) bool {
    if (names.len == 0) return false;
    const state = processTreeState(pid, 0);
    if (ignoreMatches(state.icon, names)) return true;
    return commandMatchesAny(pid, names);
}

fn commandMatchesAny(pid: u64, names: anytype) bool {
    var comm_buf: [256]u8 = undefined;
    if (readProcFile(pid, "comm", &comm_buf)) |comm_raw| {
        const comm = std.mem.trim(u8, comm_raw, &std.ascii.whitespace);
        if (nameListContains(names, comm)) return true;
    }

    var cmdline_buf: [4096]u8 = undefined;
    if (readProcFile(pid, "cmdline", &cmdline_buf)) |cmdline| {
        var args = std.mem.splitScalar(u8, cmdline, 0);
        const argv0 = args.next() orelse "";
        const command = std.fs.path.basename(argv0);
        if (nameListContains(names, command)) return true;
        if (iconForWrapperPath(argv0)) |icon| {
            if (ignoreMatches(icon, names)) return true;
        }
        if (isRuntime(command)) {
            if (args.next()) |script| {
                if (iconForWrapperPath(script)) |icon| {
                    if (ignoreMatches(icon, names)) return true;
                }
                if (nameListContains(names, std.fs.path.basename(script)))
                    return true;
            }
        }
    }
    return false;
}

fn nameListContains(names: anytype, value: []const u8) bool {
    for (names) |raw| {
        const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(name, value)) return true;
    }
    return false;
}

pub fn processTreeState(pid: u64, depth: u8) ProcessState {
    const state = processStateForPid(pid);
    if (state.remote) return state;

    // The shell integration wraps SSH as `holoctty +ssh`, so the PTY
    // foreground process can be the wrapper while ssh is its child.
    // Inspect descendants before falling back to the wrapper's icon.
    if (depth < 4) {
        var children_buf: [1024]u8 = undefined;
        if (readProcChildren(pid, &children_buf)) |children_raw| {
            var children = std.mem.tokenizeAny(u8, children_raw, &std.ascii.whitespace);
            while (children.next()) |child_raw| {
                const child_pid = std.fmt.parseInt(u64, child_raw, 10) catch continue;
                const child_state = processTreeState(child_pid, depth + 1);
                if (child_state.remote) return child_state;
                if (!std.mem.eql(u8, child_state.icon, default_icon))
                    return child_state;
            }
        }
    }

    return state;
}

pub fn processStateForPid(pid: u64) ProcessState {
    var cmdline_buf: [4096]u8 = undefined;
    const cmdline = readProcFile(pid, "cmdline", &cmdline_buf) orelse "";
    const state = processStateForCmdline(cmdline);
    if (state.remote or !std.mem.eql(u8, state.icon, default_icon))
        return state;

    var comm_buf: [256]u8 = undefined;
    if (readProcFile(pid, "comm", &comm_buf)) |comm_raw| {
        const comm = std.mem.trim(u8, comm_raw, &std.ascii.whitespace);
        if (iconForCommand(comm)) |icon| return .{
            .icon = icon,
            .interactive_shell = isShellIcon(icon),
        };
    }
    return state;
}

fn readProcChildren(pid: u64, buf: []u8) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "task/{d}/children", .{pid}) catch
        return null;
    return readProcFile(pid, name, buf);
}

pub fn processStateForCmdline(cmdline: []const u8) ProcessState {
    var args = std.mem.splitScalar(u8, cmdline, 0);
    const argv0 = args.next() orelse "";
    const command = std.fs.path.basename(argv0);
    if (isRemoteClient(command)) return remoteProcessState(args);
    if (iconForCommand(command)) |icon| {
        if (isShellIcon(icon)) return shellProcessState(icon, args);
        return .{ .icon = icon };
    }

    if (isRuntime(command)) {
        if (args.next()) |script| {
            if (iconForWrapperPath(script)) |icon| return .{ .icon = icon };
        }
    }
    return .{};
}

fn shellProcessState(icon: [:0]const u8, args: anytype) ProcessState {
    var remaining = args;
    while (remaining.next()) |arg| {
        if (arg.len == 0) continue;
        // Login/interactive flags still describe an idle shell. A command,
        // script, or `-c` payload means the shell itself is useful activity.
        if (std.mem.eql(u8, arg, "-c") or arg[0] != '-')
            return .{ .icon = icon };
    }
    return .{ .icon = icon, .interactive_shell = true };
}

fn isRemoteClient(command: []const u8) bool {
    return std.ascii.eqlIgnoreCase(command, "ssh") or
        std.ascii.eqlIgnoreCase(command, "mosh");
}

fn remoteProcessState(args: anytype) ProcessState {
    var iterator = args;
    var destination_seen = false;
    var skip_option_value = false;
    var state: ProcessState = .{ .remote = true };
    while (iterator.next()) |arg| {
        if (arg.len == 0) continue;
        if (skip_option_value) {
            skip_option_value = false;
            continue;
        }
        if (!destination_seen) {
            if (std.mem.eql(u8, arg, "--")) continue;
            if (arg[0] == '-') {
                if (sshOptionNeedsValue(arg)) skip_option_value = true;
                continue;
            }
            destination_seen = true;
            const at = std.mem.lastIndexOfScalar(u8, arg, '@');
            const host = if (at) |index| arg[index + 1 ..] else arg;
            const len = @min(host.len, state.host.len);
            @memcpy(state.host[0..len], host[0..len]);
            state.host_len = len;
            continue;
        }
        var words = std.mem.tokenizeAny(u8, arg, &std.ascii.whitespace);
        const command = std.fs.path.basename(words.next() orelse arg);
        if (iconForCommand(command)) |icon| state.icon = icon;
        if (iconForWrapperPath(arg)) |icon| state.icon = icon;
        return state;
    }
    return state;
}

fn sshOptionNeedsValue(arg: []const u8) bool {
    if (arg.len != 2) return false;
    return std.mem.indexOfScalar(u8, "bcDEeFIiJLlmOoPpQRSWw", arg[1]) != null;
}

fn readProcFile(
    pid: u64,
    name: []const u8,
    buf: []u8,
) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "/proc/{d}/{s}",
        .{ pid, name },
    ) catch return null;
    var file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch
        return null;
    defer file.close(global.io());
    const size = file.readPositionalAll(global.io(), buf, 0) catch
        return null;
    return buf[0..size];
}

pub fn iconForCommand(command: []const u8) ?[:0]const u8 {
    const mappings = [_]struct {
        names: []const []const u8,
        icon: [:0]const u8,
    }{
        // AI coding agents
        .{ .names = &.{ "codex", "codex-cli" }, .icon = "holoctty-cli-agent-codex-symbolic" },
        .{ .names = &.{"claude"}, .icon = "holoctty-cli-agent-claude-symbolic" },
        .{ .names = &.{ "gemini", "gemini-cli" }, .icon = "holoctty-cli-agent-gemini-symbolic" },
        .{ .names = &.{ "opencode", "opencode2" }, .icon = "holoctty-cli-agent-opencode-symbolic" },
        .{ .names = &.{ "grok", "grok-build" }, .icon = "holoctty-cli-agent-grok-symbolic" },
        .{ .names = &.{ "cursor", "cursor-agent" }, .icon = "holoctty-cli-agent-cursor-symbolic" },
        .{ .names = &.{ "copilot", "github-copilot", "copilot-cli" }, .icon = "holoctty-cli-agent-copilot-symbolic" },
        .{ .names = &.{"amp"}, .icon = "holoctty-cli-agent-amp-symbolic" },
        .{ .names = &.{"pi"}, .icon = "holoctty-cli-agent-pi-symbolic" },
        .{ .names = &.{ "omp", "oh-my-pi" }, .icon = "holoctty-cli-agent-omp-symbolic" },
        .{ .names = &.{ "devin", "devin-cli" }, .icon = "holoctty-cli-agent-devin-symbolic" },
        .{ .names = &.{"aider"}, .icon = "holoctty-cli-agent-aider-symbolic" },
        .{ .names = &.{ "goose", "goose-cli" }, .icon = "holoctty-cli-agent-goose-symbolic" },
        .{ .names = &.{"crush"}, .icon = "holoctty-cli-agent-crush-symbolic" },
        .{ .names = &.{ "cline", "cline-cli" }, .icon = "holoctty-cli-agent-cline-symbolic" },
        .{ .names = &.{ "droid", "factory", "factory-droid" }, .icon = "holoctty-cli-agent-droid-symbolic" },
        .{ .names = &.{ "kilo", "kilocode", "kilo-code" }, .icon = "holoctty-cli-agent-kilo-symbolic" },
        .{ .names = &.{ "kimi", "kimi-cli", "kimi-code" }, .icon = "holoctty-cli-agent-kimi-symbolic" },
        .{ .names = &.{ "qwen", "qwen-code", "qwen-cli" }, .icon = "holoctty-cli-agent-qwen-symbolic" },
        .{ .names = &.{ "auggie", "augment", "augment-cli" }, .icon = "holoctty-cli-agent-auggie-symbolic" },
        .{ .names = &.{ "hermes", "hermes-agent" }, .icon = "holoctty-cli-agent-hermes-symbolic" },
        .{ .names = &.{"plandex"}, .icon = "holoctty-cli-agent-plandex-symbolic" },
        .{ .names = &.{ "openhands", "open-hands", "openhands-cli" }, .icon = "holoctty-cli-agent-openhands-symbolic" },
        .{ .names = &.{ "continue", "cn", "continue-cli" }, .icon = "holoctty-cli-agent-continue-symbolic" },
        .{ .names = &.{ "q", "amazon-q", "amazonq", "q-chat" }, .icon = "holoctty-cli-agent-amazonq-symbolic" },
        // Shells
        .{ .names = &.{"bash"}, .icon = "holoctty-cli-shell-bash-symbolic" },
        .{ .names = &.{"zsh"}, .icon = "holoctty-cli-shell-zsh-symbolic" },
        .{ .names = &.{"fish"}, .icon = "holoctty-cli-shell-fish-symbolic" },
        .{ .names = &.{ "nu", "nushell" }, .icon = "holoctty-cli-shell-nushell-symbolic" },
        .{ .names = &.{ "pwsh", "powershell" }, .icon = "holoctty-cli-shell-powershell-symbolic" },
        // Popular TUIs
        .{ .names = &.{ "lazygit", "lg" }, .icon = "holoctty-cli-tui-lazygit-symbolic" },
        .{ .names = &.{"gitui"}, .icon = "holoctty-cli-tui-gitui-symbolic" },
        .{ .names = &.{"lazydocker"}, .icon = "holoctty-cli-tui-lazydocker-symbolic" },
        .{ .names = &.{ "docker", "docker-compose", "podman" }, .icon = "holoctty-cli-tui-docker-symbolic" },
        .{ .names = &.{ "btop", "btop++", "htop", "bottom", "btm", "bashtop", "glances" }, .icon = "holoctty-cli-tui-btop-symbolic" },
        .{ .names = &.{ "k9s", "kubectl", "helm" }, .icon = "holoctty-cli-tui-k8s-symbolic" },
        .{ .names = &.{ "nvim", "neovim" }, .icon = "holoctty-cli-tui-nvim-symbolic" },
        .{ .names = &.{ "vim", "vim.basic", "vim.tiny" }, .icon = "holoctty-cli-tui-vim-symbolic" },
        .{ .names = &.{ "helix", "hx" }, .icon = "holoctty-cli-tui-helix-symbolic" },
        .{ .names = &.{"yazi"}, .icon = "holoctty-cli-tui-yazi-symbolic" },
        .{ .names = &.{ "ranger", "nnn", "lf", "fff", "xplr" }, .icon = "holoctty-cli-tui-ranger-symbolic" },
        .{ .names = &.{"glow"}, .icon = "holoctty-cli-tui-glow-symbolic" },
        .{ .names = &.{ "superfile", "spf" }, .icon = "holoctty-cli-tui-superfile-symbolic" },
        .{ .names = &.{"tig"}, .icon = "holoctty-cli-tui-tig-symbolic" },
    };

    for (mappings) |mapping| {
        for (mapping.names) |name| {
            if (std.ascii.eqlIgnoreCase(command, name)) return mapping.icon;
        }
    }
    return null;
}

fn isRuntime(command: []const u8) bool {
    const runtimes = [_][]const u8{
        "node", "nodejs", "bun",  "deno", "python", "python3", "python3.11", "python3.12", "python3.13",
        "uv",   "uvx",    "pipx",
    };
    for (runtimes) |runtime| {
        if (std.ascii.eqlIgnoreCase(command, runtime)) return true;
    }
    // Match versioned interpreters like python3.11
    if (std.ascii.startsWithIgnoreCase(command, "python")) return true;
    return false;
}

pub fn iconForWrapperPath(path: []const u8) ?[:0]const u8 {
    const mappings = [_]struct {
        needle: []const u8,
        icon: [:0]const u8,
    }{
        .{ .needle = "@openai/codex", .icon = "holoctty-cli-agent-codex-symbolic" },
        .{ .needle = "/codex/", .icon = "holoctty-cli-agent-codex-symbolic" },
        .{ .needle = "@anthropic-ai/claude", .icon = "holoctty-cli-agent-claude-symbolic" },
        .{ .needle = "/claude-code/", .icon = "holoctty-cli-agent-claude-symbolic" },
        .{ .needle = "@google/gemini", .icon = "holoctty-cli-agent-gemini-symbolic" },
        .{ .needle = "/opencode/", .icon = "holoctty-cli-agent-opencode-symbolic" },
        .{ .needle = "/opencode2/", .icon = "holoctty-cli-agent-opencode-symbolic" },
        .{ .needle = "/grok/", .icon = "holoctty-cli-agent-grok-symbolic" },
        .{ .needle = "/cursor-agent/", .icon = "holoctty-cli-agent-cursor-symbolic" },
        .{ .needle = "/copilot/", .icon = "holoctty-cli-agent-copilot-symbolic" },
        .{ .needle = "/amp/", .icon = "holoctty-cli-agent-amp-symbolic" },
        .{ .needle = "@oh-my-pi/", .icon = "holoctty-cli-agent-omp-symbolic" },
        .{ .needle = "/oh-my-pi/", .icon = "holoctty-cli-agent-omp-symbolic" },
        .{ .needle = "@mariozechner/pi", .icon = "holoctty-cli-agent-pi-symbolic" },
        .{ .needle = "@earendil-works/pi", .icon = "holoctty-cli-agent-pi-symbolic" },
        .{ .needle = "/pi-coding-agent/", .icon = "holoctty-cli-agent-pi-symbolic" },
        .{ .needle = "/devin/", .icon = "holoctty-cli-agent-devin-symbolic" },
        .{ .needle = "cli.devin.ai", .icon = "holoctty-cli-agent-devin-symbolic" },
        .{ .needle = "/aider", .icon = "holoctty-cli-agent-aider-symbolic" },
        .{ .needle = "aider-chat", .icon = "holoctty-cli-agent-aider-symbolic" },
        .{ .needle = "/goose/", .icon = "holoctty-cli-agent-goose-symbolic" },
        .{ .needle = "block/goose", .icon = "holoctty-cli-agent-goose-symbolic" },
        .{ .needle = "aaif-goose", .icon = "holoctty-cli-agent-goose-symbolic" },
        .{ .needle = "/crush/", .icon = "holoctty-cli-agent-crush-symbolic" },
        .{ .needle = "@charmland/crush", .icon = "holoctty-cli-agent-crush-symbolic" },
        .{ .needle = "charmbracelet/crush", .icon = "holoctty-cli-agent-crush-symbolic" },
        .{ .needle = "/cline/", .icon = "holoctty-cli-agent-cline-symbolic" },
        .{ .needle = "@cline/", .icon = "holoctty-cli-agent-cline-symbolic" },
        .{ .needle = "/droid/", .icon = "holoctty-cli-agent-droid-symbolic" },
        .{ .needle = "factory/droid", .icon = "holoctty-cli-agent-droid-symbolic" },
        .{ .needle = "/kilocode/", .icon = "holoctty-cli-agent-kilo-symbolic" },
        .{ .needle = "/kilo-code/", .icon = "holoctty-cli-agent-kilo-symbolic" },
        .{ .needle = "/kimi/", .icon = "holoctty-cli-agent-kimi-symbolic" },
        .{ .needle = "/qwen-code/", .icon = "holoctty-cli-agent-qwen-symbolic" },
        .{ .needle = "@qwen-code/", .icon = "holoctty-cli-agent-qwen-symbolic" },
        .{ .needle = "/auggie/", .icon = "holoctty-cli-agent-auggie-symbolic" },
        .{ .needle = "augmentcode", .icon = "holoctty-cli-agent-auggie-symbolic" },
        .{ .needle = "/hermes/", .icon = "holoctty-cli-agent-hermes-symbolic" },
        .{ .needle = "hermes-agent", .icon = "holoctty-cli-agent-hermes-symbolic" },
        .{ .needle = "/plandex/", .icon = "holoctty-cli-agent-plandex-symbolic" },
        .{ .needle = "/openhands/", .icon = "holoctty-cli-agent-openhands-symbolic" },
        .{ .needle = "OpenHands", .icon = "holoctty-cli-agent-openhands-symbolic" },
        .{ .needle = "/continue/", .icon = "holoctty-cli-agent-continue-symbolic" },
        .{ .needle = "@continuedev/", .icon = "holoctty-cli-agent-continue-symbolic" },
        .{ .needle = "amazon-q", .icon = "holoctty-cli-agent-amazonq-symbolic" },
        .{ .needle = "amazonq", .icon = "holoctty-cli-agent-amazonq-symbolic" },
    };
    for (mappings) |mapping| {
        if (std.mem.indexOf(u8, path, mapping.needle) != null)
            return mapping.icon;
    }
    return null;
}

test "CLI process distinguishes idle shells from shell tasks" {
    const idle = processStateForCmdline("zsh\x00");
    try std.testing.expect(idle.interactive_shell);

    const login = processStateForCmdline("bash\x00-l\x00");
    try std.testing.expect(login.interactive_shell);

    const script = processStateForCmdline("bash\x00build.sh\x00");
    try std.testing.expect(!script.interactive_shell);

    const command = processStateForCmdline("fish\x00-c\x00sleep 10\x00");
    try std.testing.expect(!command.interactive_shell);
}

test "CLI process classifies configurable icon groups" {
    try std.testing.expect(isShellIcon("holoctty-cli-shell-zsh-symbolic"));
    try std.testing.expect(!isShellIcon("holoctty-cli-tui-nvim-symbolic"));
    try std.testing.expect(isTuiIcon("holoctty-cli-tui-nvim-symbolic"));
    try std.testing.expect(!isTuiIcon("holoctty-cli-agent-codex-symbolic"));
}

test "extend-full ignore matches command aliases and display names" {
    const omp = "holoctty-cli-agent-omp-symbolic";
    const codex = "holoctty-cli-agent-codex-symbolic";

    try std.testing.expect(ignoreMatches(omp, &.{"omp"}));
    try std.testing.expect(ignoreMatches(omp, &.{"oh-my-pi"}));
    try std.testing.expect(ignoreMatches(omp, &.{"OMP"}));
    try std.testing.expect(ignoreMatches(codex, &.{"Codex"}));
    try std.testing.expect(!ignoreMatches(omp, &.{"codex"}));
    try std.testing.expect(!ignoreMatches(codex, &.{"omp"}));
    try std.testing.expect(!ignoreMatches(omp, &.{""}));
}
