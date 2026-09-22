// Builds the talk as a .pptx; convert to LibreOffice Impress with:
//   soffice --headless --convert-to odp agent-sandbox-talk.pptx
// Usage: node build-slides.js [output.pptx]
const pptxgen = require("pptxgenjs");
const out = process.argv[2] || "agent-sandbox-talk.pptx";

const pres = new pptxgen();
pres.layout = "LAYOUT_16x9"; // 10 x 5.625 in
pres.author = "Corwin Joy";
pres.title = "Agent Sandboxing";

// Palette: dark slate dominates, teal = boundary / safe, amber = attention, rust = risk.
const INK = "1B2430", PAPER = "FFFFFF", MIST = "EEF2F6", TEAL = "1F8A83", AMBER = "E09F3E",
  RUST = "B5483A", MUTED = "5B6775", LINE = "C9D2DC", PALE = "DCEFED";
const F = "Liberation Sans"; // bundled with LibreOffice on every platform

// ---------- helpers ----------
const tb = (o) => Object.assign({ fontFace: F, margin: 0, isTextBox: true, valign: "top" }, o);
function heading(s, text, sub, dark) {
  s.addText(text, tb({ x: 0.5, y: 0.35, w: 9, h: 0.65, fontSize: 30, bold: true, color: dark ? PAPER : INK }));
  if (sub) s.addText(sub, tb({ x: 0.5, y: 0.98, w: 9, h: 0.4, fontSize: 14, color: dark ? "B8C4D0" : MUTED }));
}
function pageNo(s, n, dark) {
  s.addText(String(n), tb({ x: 9.0, y: 5.2, w: 0.5, h: 0.25, fontSize: 10, align: "right", color: dark ? "8FA0B2" : MUTED }));
}
function card(s, x, y, w, h, fill) {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.08, fill: { color: fill || MIST }, line: { color: fill || MIST, width: 0 } });
}
// The motif: a dashed rounded outline = a boundary.
function boundary(s, x, y, w, h, color) {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.1, fill: { color: PAPER, transparency: 100 }, line: { color: color || TEAL, width: 1.75, dashType: "dash" } });
}
function badge(s, x, y, label, color) {
  s.addShape(pres.shapes.OVAL, { x, y, w: 0.46, h: 0.46, fill: { color: color || TEAL }, line: { color: color || TEAL, width: 0 } });
  s.addText(label, tb({ x, y, w: 0.46, h: 0.46, fontSize: 15, bold: true, color: PAPER, align: "center", valign: "middle" }));
}
function bullets(items, opts) {
  return items.map((t, i) => ({ text: t, options: Object.assign({ bullet: true, breakLine: i < items.length - 1, paraSpaceAfter: 6 }, opts || {}) }));
}
function arrow(s, x, y, w, color) {
  s.addShape(pres.shapes.LINE, { x, y, w, h: 0, line: { color: color || INK, width: 1.75, endArrowType: "triangle" } });
}
let n = 0;
function slide(dark) { const s = pres.addSlide(); s.background = { color: dark ? INK : PAPER }; n += 1; if (n > 1) pageNo(s, n, dark); return s; }

// ---------- 1. title ----------
{
  const s = slide(true);
  boundary(s, 0.5, 0.5, 9, 4.6, TEAL);
  s.addText("Agent Sandboxing", tb({ x: 1.0, y: 1.45, w: 8, h: 0.9, fontSize: 42, bold: true, color: PAPER }));
  s.addText("Why approving prompts is not a security boundary,\nand the sandbox I ended up building", tb({ x: 1.0, y: 2.45, w: 7.4, h: 0.9, fontSize: 18, color: "B8C4D0" }));
  s.addText("Corwin Joy", tb({ x: 1.0, y: 4.0, w: 5, h: 0.35, fontSize: 14, color: PAPER }));
  s.addText("github.com/corwinjoy/agent-sandbox", tb({ x: 1.0, y: 4.35, w: 6, h: 0.35, fontSize: 14, color: AMBER }));
  s.addNotes("This is the story of how I went from 'I will just approve each command' to running my coding agent inside a container with no route to the internet and a token that works on one repository. The dashed outline you will see on most slides stands for a boundary.");
}

// ---------- 2. attack surface ----------
{
  const s = slide();
  heading(s, "1. Understand the agent attack surface", "A coding agent acts with your privileges in three places.");
  const cols = [
    ["Local system", "Everything your user can read or run.", ["Source, SSH keys, cloud credentials, browser profiles", "Shell startup files and PATH", "The kernel and the GPU driver underneath"]],
    ["Services", "Everything your tokens can do.", ["GitHub, cloud APIs, package registries", "MCP servers and the tools they expose", "Principle of least privilege!"]],
    ["Generated code", "Everything it writes, installs and runs.", ["Code it wrote a minute ago, run without review", "Dependencies and their install scripts", "Build files you run later on the host"]],
  ];
  cols.forEach((c, i) => {
    const x = 0.5 + i * 3.07;
    card(s, x, 1.6, 2.87, 3.3);
    badge(s, x + 0.25, 1.85, String(i + 1), TEAL);
    s.addText(c[0], tb({ x: x + 0.85, y: 1.85, w: 1.9, h: 0.46, fontSize: 18, bold: true, color: INK, valign: "middle" }));
    s.addText(c[1], tb({ x: x + 0.25, y: 2.5, w: 2.4, h: 0.5, fontSize: 13, italic: true, color: MUTED }));
    s.addText(bullets(c[2]), tb({ x: x + 0.25, y: 3.1, w: 2.45, h: 1.7, fontSize: 12, color: INK }));
  });
  s.addNotes("Start with what the agent can touch. It runs as me, so locally it has everything I have. It holds my tokens, so on services it can do whatever they allow. And it writes and runs code, including other people's code that it installs.");
}

// ---------- 3. mechanisms ----------
{
  const s = slide();
  heading(s, "2. How it goes wrong", "Three mechanisms. None of them needs an exploit.");
  const rows = [
    ["Bad hooks", RUST, "A cloned repository can ship scripts that run automatically.", "A hook named lint-check.sh greps your environment for AWS and API keys, lists ~/.ssh/id_*, posts both to a remote server, and exits 0 so nothing looks wrong. (Bruniaux)"],
    ["Overeager AI", AMBER, "The agent treats a block as a puzzle to solve.", "npx was on a deny list. The agent ran it anyway via the path /proc/self/root/usr/bin/npx, which the rule did not match. When the sandbox stopped that, it asked to run outside the sandbox. (Ona)"],
    ["Malicious prompts", RUST, "Text the agent reads carries instructions: issues, READMEs, web pages, tool output.", "Invariant Labs, 2025: an issue in a public repo made an agent copy private-repo data into a public pull request."],
  ];
  rows.forEach((r, i) => {
    const y = 1.55 + i * 1.2;
    card(s, 0.5, y, 9, 1.05);
    s.addShape(pres.shapes.OVAL, { x: 0.72, y: y + 0.3, w: 0.44, h: 0.44, fill: { color: r[1] }, line: { color: r[1], width: 0 } });
    s.addText("!", tb({ x: 0.72, y: y + 0.3, w: 0.44, h: 0.44, fontSize: 16, bold: true, color: PAPER, align: "center", valign: "middle" }));
    s.addText(r[0], tb({ x: 1.35, y: y + 0.12, w: 2.0, h: 0.8, fontSize: 17, bold: true, color: INK, valign: "middle" }));
    s.addText(r[2], tb({ x: 3.3, y: y + 0.12, w: 2.7, h: 0.85, fontSize: 11.5, color: INK, valign: "middle" }));
    s.addText(r[3], tb({ x: 6.2, y: y + 0.12, w: 3.15, h: 0.85, fontSize: 11, italic: true, color: MUTED, valign: "middle" }));
  });
  const src = [
    ["Bruniaux, Claude Code attack surface", "https://www.florian.bruniaux.com/guides/claude-code-attack-surface/"],
    ["Ona, how Claude Code escapes its sandbox", "https://ona.com/stories/how-claude-code-escapes-its-own-denylist-and-sandbox"],
    ["Invariant Labs, GitHub MCP exploited", "https://invariantlabs.ai/blog/mcp-github-vulnerability"],
  ];
  s.addText(src.flatMap((l, i) => [{ text: l[0], options: { hyperlink: { url: l[1] }, color: TEAL } }].concat(i < src.length - 1 ? [{ text: "   |   ", options: { color: MUTED } }] : [])),
    tb({ x: 0.5, y: 5.2, w: 8.4, h: 0.28, fontSize: 9.5, color: TEAL }));
  s.addNotes("Bad hooks: repository config is code, and a headless run never even shows a trust dialog. Overeager AI: the model is trying to help, so a blocked command becomes a puzzle to solve. Malicious prompts: anything the agent reads can steer it, and a well-aligned model did not save the GitHub MCP demo.");
}

// ---------- 4. the statement ----------
{
  const s = slide(true);
  s.addText("3.", tb({ x: 0.5, y: 0.45, w: 1, h: 0.5, fontSize: 20, bold: true, color: AMBER }));
  s.addText("Governing this by approving prompts is a recipe for failure.", tb({ x: 0.5, y: 1.0, w: 5.2, h: 2.6, fontSize: 34, bold: true, color: PAPER }));
  s.addText("Just click yes!", tb({ x: 0.5, y: 3.85, w: 5.0, h: 0.9, fontSize: 15, italic: true, color: "B8C4D0" }));
  const ev = [
    ["Approval fatigue", "Dozens of prompts a session train you to click yes. The dangerous one looks like the rest."],
    ["An honest ask still gets through", "Ona's agent wrote \"run npx via full path to bypass deny rule\" in the prompt. It was lost among the others."],
    ["One \"always allow\" is enough", "The GitHub MCP exploit needed a single standing approval."],
    ["Headless runs never ask", "claude -p shows no trust dialog at all."],
  ];
  ev.forEach((e, i) => {
    const y = 0.75 + i * 1.12;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 6.0, y, w: 3.5, h: 1.0, rectRadius: 0.08, fill: { color: "263241" }, line: { color: "263241", width: 0 } });
    s.addText(e[0], tb({ x: 6.2, y: y + 0.1, w: 3.1, h: 0.3, fontSize: 13, bold: true, color: AMBER }));
    s.addText(e[1], tb({ x: 6.2, y: y + 0.4, w: 3.1, h: 0.55, fontSize: 10.5, color: "D5DDE6" }));
  });
  s.addNotes("This is the turning point of the talk. I started out approving prompts. It does not scale, it does not survive fatigue, and NVIDIA's AI red team calls out the same habituation problem. A control has to hold when I am not paying attention.");
}

// ---------- 5. boundaries ----------
{
  const s = slide();
  heading(s, "4. Agents need clear boundaries", "Limits that hold whether or not anyone is watching.");
  const rows = [
    ["Restricted local machine", "The agent sees one project directory. No home directory, no keys, no capabilities.", "Rootless container, only the project mounted"],
    ["Restricted service permissions", "Each credential can do one narrow job, so a misled agent has little to misuse.", "GitHub token for one repository: read, commit, push, comment"],
    ["Limited ability to exfiltrate", "Stolen data needs somewhere to go. Take the routes away.", "No route out, no DNS. One proxy with a domain allowlist"],
  ];
  s.addText("Principle", tb({ x: 1.2, y: 1.5, w: 2.6, h: 0.3, fontSize: 11, bold: true, color: MUTED }));
  s.addText("What it means", tb({ x: 3.9, y: 1.5, w: 2.9, h: 0.3, fontSize: 11, bold: true, color: MUTED }));
  s.addText("In this project", tb({ x: 6.95, y: 1.5, w: 2.5, h: 0.3, fontSize: 11, bold: true, color: MUTED }));
  rows.forEach((r, i) => {
    const y = 1.85 + i * 1.05;
    boundary(s, 0.5, y, 9, 0.9, TEAL);
    badge(s, 0.65, y + 0.22, String(i + 1), TEAL);
    s.addText(r[0], tb({ x: 1.2, y: y + 0.08, w: 2.6, h: 0.75, fontSize: 15, bold: true, color: INK, valign: "middle" }));
    s.addText(r[1], tb({ x: 3.9, y: y + 0.08, w: 2.9, h: 0.75, fontSize: 11.5, color: INK, valign: "middle" }));
    s.addText(r[2], tb({ x: 6.95, y: y + 0.08, w: 2.45, h: 0.75, fontSize: 11.5, color: TEAL, bold: true, valign: "middle" }));
  });
  s.addNotes("Three boundaries, one for each part of the attack surface. Simon Willison's lethal trifecta is private data, untrusted content and a way to send data out. You rarely get to remove untrusted content, so shrink the other two.");
}

// ---------- 6. community + what I tried ----------
{
  const s = slide();
  heading(s, "5. The community agrees on the shape", "Different authors, the same three boundaries.");
  card(s, 0.5, 1.55, 5.0, 3.45);
  const voices = [
    ["NVIDIA AI red team", "Mandatory: egress allowlist, no writes outside the workspace, no writes to agent config. Prefer VMs to shared-kernel sandboxes."],
    ["Anthropic", "Run unattended agents in a container, a VM or the sandbox runtime, so hooks and MCP servers are inside the boundary too."],
    ["Simon Willison", "The lethal trifecta: private data, untrusted content, a way to send data out."],
    ["Arcade", "A sandbox limits where code runs, not what the agent is authorised to do. Least privilege, no credentials in the model's reach."],
  ];
  voices.forEach((v, i) => {
    const y = 1.7 + i * 0.82;
    s.addText(v[0], tb({ x: 0.75, y, w: 4.5, h: 0.25, fontSize: 12.5, bold: true, color: TEAL }));
    s.addText(v[1], tb({ x: 0.75, y: y + 0.25, w: 4.55, h: 0.52, fontSize: 10.5, color: INK }));
  });
  s.addText("What I tried, in order", tb({ x: 5.9, y: 1.55, w: 3.6, h: 0.3, fontSize: 14, bold: true, color: INK }));
  const tried = [
    ["Plain Docker container", "Root daemon, shared kernel", RUST],
    ["Claude Code's sandbox", "Bash only, no GPU", RUST],
    ["Docker Sandboxes", "Strong, but no GPU or perf for me", AMBER],
    ["NVIDIA OpenShell", "Best network design; alpha, no perf", AMBER],
    ["Rootless Podman + scoped token", "What this project is", TEAL],
  ];
  tried.forEach((t, i) => {
    const y = 1.95 + i * 0.64;
    badge(s, 5.9, y + 0.05, String(i + 1), t[2]);
    s.addText(t[0], tb({ x: 6.5, y, w: 3.0, h: 0.3, fontSize: 12.5, bold: true, color: INK }));
    s.addText(t[1], tb({ x: 6.5, y: y + 0.3, w: 3.0, h: 0.28, fontSize: 11, color: MUTED }));
  });
  s.addNotes("I did not invent any of this. NVIDIA, Anthropic, Docker and independent writers all land on the same controls. What differed for me was the constraint: I need CUDA on a laptop whose GPU I am also using, and hardware performance counters. The next four slides are the options I went through.");
}

// ---------- 7. why not just docker ----------
{
  const s = slide();
  heading(s, "6. Why not just Docker?", "A container is packaging. It was never meant to hold hostile code.");
  s.addText(bullets([
    "The Docker daemon runs as root, and the docker group is root: docker run -v /:/host needs no password.",
    "Containers share the host kernel, so one kernel or runtime bug is a host compromise.",
    "Most real escapes are configuration: --privileged, a mounted docker.sock, broad host mounts.",
    "Egress control and credential handling are left entirely to you.",
  ]), tb({ x: 0.5, y: 1.6, w: 5.3, h: 3.3, fontSize: 13.5, color: INK }));
  const cves = [
    ["CVE-2025-52881", "runc, Nov 2025", "A hostile Dockerfile or container redirects runc's /proc writes and gains host root."],
    ["CVE-2025-23266", "NVIDIAScape, CVSS 9.0", "A three-line Dockerfile gets host root through the NVIDIA Container Toolkit's hook."],
  ];
  cves.forEach((c, i) => {
    const y = 1.6 + i * 1.7;
    card(s, 6.1, y, 3.4, 1.5, "FBEDEA");
    s.addText(c[0], tb({ x: 6.3, y: y + 0.12, w: 3.0, h: 0.35, fontSize: 17, bold: true, color: RUST }));
    s.addText(c[1], tb({ x: 6.3, y: y + 0.47, w: 3.0, h: 0.25, fontSize: 11, bold: true, color: INK }));
    s.addText(c[2], tb({ x: 6.3, y: y + 0.75, w: 3.0, h: 0.7, fontSize: 10.5, color: INK }));
  });
  s.addNotes("My own user was in the docker group when I started, which meant any process running as me was one command from root. Both CVEs on the right were fixed in 2025, and both trigger when a container is built or created from attacker-controlled input, which is exactly what an agent can supply.");
}

// ---------- 8. why not the Claude sandbox ----------
{
  const s = slide();
  heading(s, "7. Why not Claude Code's own sandbox?", "A useful layer. Not a boundary you can leave unattended.");
  const pts = [
    ["Overeager to \"just do it\"", "When a command fails inside the sandbox, the default is to retry it outside. You have to switch that off (allowUnsandboxedCommands: false)."],
    ["It covers Bash only", "Hooks and MCP servers run on the host as you. Anthropic's docs say so, and recommend a container or VM for unattended work."],
    ["It wants your whole machine", "By default it can read everything you can, including ~/.ssh and ~/.aws. If dependencies are missing it silently runs unsandboxed."],
    ["File rules are tricky and come in two sets", "One set for Bash (sandbox denyRead / credentials), another for Claude's Read tool (permission rules). The overlap is unclear, so you write everything twice."],
  ];
  pts.forEach((p, i) => {
    const x = 0.5 + (i % 2) * 4.6, y = 1.55 + Math.floor(i / 2) * 1.62;
    card(s, x, y, 4.4, 1.47);
    s.addText(p[0], tb({ x: x + 0.2, y: y + 0.12, w: 4.0, h: 0.32, fontSize: 13.5, bold: true, color: RUST }));
    s.addText(p[1], tb({ x: x + 0.2, y: y + 0.47, w: 4.0, h: 0.95, fontSize: 11, color: INK }));
  });
  s.addText("And for my work: it builds a fresh /dev, so there is no GPU. An open request for device passthrough has had no reply since December 2025.", tb({ x: 0.5, y: 4.85, w: 8.4, h: 0.4, fontSize: 11, italic: true, color: MUTED }));
  s.addNotes("I still use these settings on the host, hardened: fail if unavailable, no unsandboxed retry, credentials denied in both rule sets. But the design wraps individual shell commands, and the things I worry about most, hooks and MCP servers, are outside it.");
}

// ---------- 9. why not docker sandboxes ----------
{
  const s = slide();
  heading(s, "8. Why not Docker Sandboxes?", "The strongest ready-made option. It did not fit GPU and profiling work.");
  s.addText("Why I did not use it", tb({ x: 0.5, y: 1.5, w: 4.4, h: 0.3, fontSize: 14, bold: true, color: RUST }));
  const no = [
    ["Opaque template", "The agent environment is an image on Docker Hub. Hard to read, and a tag can change underneath you."],
    ["GPU support", "Experimental VFIO passthrough needs a GPU nothing else is using. On my laptop it crashed the machine."],
    ["No hardware perf counters", "perf stat shows cycles, instructions and cache-misses as <not supported> inside the VM."],
  ];
  no.forEach((r, i) => {
    const y = 1.9 + i * 1.02;
    card(s, 0.5, y, 4.4, 0.9, "FBEDEA");
    s.addText(r[0], tb({ x: 0.7, y: y + 0.08, w: 4.0, h: 0.28, fontSize: 12.5, bold: true, color: INK }));
    s.addText(r[1], tb({ x: 0.7, y: y + 0.36, w: 4.0, h: 0.5, fontSize: 10.5, color: INK }));
  });
  s.addText("What it does better", tb({ x: 5.1, y: 1.5, w: 4.4, h: 0.3, fontSize: 14, bold: true, color: TEAL }));
  const yes = [
    ["Its own kernel", "A microVM per sandbox. Kernel and runtime bugs stay inside."],
    ["Secrets never enter the sandbox", "A host-side proxy injects credentials into requests. Mine sits in an environment variable."],
    ["Clone mode and a private Docker daemon", "The agent works on a copy, and can build containers safely."],
  ];
  yes.forEach((r, i) => {
    const y = 1.9 + i * 1.02;
    card(s, 5.1, y, 4.4, 0.9, PALE);
    s.addText(r[0], tb({ x: 5.3, y: y + 0.08, w: 4.0, h: 0.28, fontSize: 12.5, bold: true, color: INK }));
    s.addText(r[1], tb({ x: 5.3, y: y + 0.36, w: 4.0, h: 0.5, fontSize: 10.5, color: INK }));
  });
  s.addText("No GPU and no profiling? Use Docker Sandboxes or another VM-based option. For hostile code, always.", tb({ x: 0.5, y: 4.95, w: 8.4, h: 0.3, fontSize: 11.5, italic: true, color: MUTED }));
  s.addNotes("I want to be fair to Docker here. On isolation it is the better tool, and the project's guide says so. My three reasons are specific to my work. If you do not need a GPU or perf counters, stop here and use it.");
}

// ---------- 9b. why not OpenShell ----------
{
  const s = slide();
  heading(s, "9. Why not NVIDIA OpenShell?", "The best network design of the group. Two of its ideas are now in this project.");
  s.addText("What it gets right", tb({ x: 0.5, y: 1.5, w: 4.4, h: 0.3, fontSize: 14, bold: true, color: TEAL }));
  const yes = [
    ["Binary identity", "Each allowed endpoint names which executables may reach it. A hook running curl is refused."],
    ["Request-level rules", "Method and path rules per endpoint. GitHub reads allowed, pushes refused, at the proxy."],
    ["Credentials never enter the sandbox", "Injected by the proxy, bound to their endpoints."],
  ];
  yes.forEach((r, i) => {
    const y = 1.9 + i * 0.92;
    card(s, 0.5, y, 4.4, 0.82, PALE);
    s.addText(r[0], tb({ x: 0.7, y: y + 0.08, w: 4.0, h: 0.26, fontSize: 12.5, bold: true, color: INK }));
    s.addText(r[1], tb({ x: 0.7, y: y + 0.34, w: 4.0, h: 0.45, fontSize: 10.5, color: INK }));
  });
  s.addText("Why not, for me, today", tb({ x: 5.1, y: 1.5, w: 4.4, h: 0.3, fontSize: 14, bold: true, color: RUST }));
  const no = [
    ["No hardware perf counters", "Its seccomp filter denies perf_event_open, with no policy switch."],
    ["Podman 5 or the Docker socket", "Ubuntu 24.04 ships Podman 4.9; the Docker driver needs root-equivalent access."],
    ["Alpha, API-key login, hooks still run", "Pre-0.1.0 changes; no subscription login documented; nothing Claude-Code-specific."],
  ];
  no.forEach((r, i) => {
    const y = 1.9 + i * 0.92;
    card(s, 5.1, y, 4.4, 0.82, "FBEDEA");
    s.addText(r[0], tb({ x: 5.3, y: y + 0.08, w: 4.0, h: 0.26, fontSize: 12.5, bold: true, color: INK }));
    s.addText(r[1], tb({ x: 5.3, y: y + 0.34, w: 4.0, h: 0.45, fontSize: 10.5, color: INK }));
  });
  s.addText("Borrowed: read-only GitHub enforced at the proxy in untrusted mode, and an audit-then-enforce workflow for the allowlist.", tb({ x: 0.5, y: 4.75, w: 9, h: 0.4, fontSize: 11.5, italic: true, color: MUTED }));
  s.addNotes("OpenShell is NVIDIA's open-source agent runtime. Its supervisor sits inside the sandbox and brokers every connect() call, which is how it knows which binary is talking and can keep credentials out of the workload. I would want that design. But it denies perf_event_open outright, needs Podman 5 or the Docker socket, and is alpha. I took two ideas from it instead.");
}

// ---------- 10. rootless podman vs docker ----------
{
  const s = slide();
  heading(s, "10. Rootless Podman vs Docker", "Same images, same commands. The difference is who is holding the keys.");
  const H = (t) => ({ text: t, options: { bold: true, color: PAPER, fill: { color: INK }, fontFace: F, fontSize: 12 } });
  const C = (t, o) => ({ text: t, options: Object.assign({ color: INK, fontFace: F, fontSize: 11.5 }, o || {}) });
  const rows = [
    [H(""), H("Docker (default)"), H("Rootless Podman")],
    [C("Daemon", { bold: true }), C("One, running as root"), C("None. Containers are your own processes")],
    [C("Who can start containers", { bold: true }), C("The docker group, which is root-equivalent"), C("Any user, with no extra privilege")],
    [C("Root inside the container", { bold: true }), C("Root on the host, unless remapped"), C("An unprivileged id on the host")],
    [C("A runtime escape lands in", { bold: true }), C("A root process"), C("Your user account")],
    [C("runc CVE-2025-52881", { bold: true }), C("Host root"), C("Maintainers: rootless \"entirely mitigates\" the escalation")],
    [C("GPU", { bold: true }), C("NVIDIA toolkit"), C("Same toolkit, through CDI")],
    [C("Still shared", { bold: true }), C("The kernel and the GPU driver"), C("The kernel and the GPU driver")],
  ];
  s.addTable(rows, { x: 0.5, y: 1.55, w: 9, colW: [2.4, 3.1, 3.5], rowH: 0.4, border: { type: "solid", color: LINE, pt: 0.75 }, fill: { color: PAPER }, valign: "middle", margin: [0.04, 0.1, 0.04, 0.1] });
  s.addNotes("Podman runs the same images with the same command line, so nothing about my workflow changed. What changed is that there is no root daemon to reach. The last row matters: rootless does not give you a separate kernel. That is the honest limit of this project.");
}

// ---------- 11. project: architecture ----------
{
  const s = slide();
  heading(s, "11. The project: what it builds", "github.com/corwinjoy/agent-sandbox");
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.5, y: 1.5, w: 6.7, h: 2.75, rectRadius: 0.1, fill: { color: "F7F9FB" }, line: { color: LINE, width: 1 } });
  s.addText("Your machine", tb({ x: 0.7, y: 1.57, w: 3, h: 0.25, fontSize: 10.5, bold: true, color: MUTED }));
  const box = (x, y, w, h, t, fill, col) => { card(s, x, y, w, h, fill); s.addText(t, tb({ x: x + 0.08, y, w: w - 0.16, h, fontSize: 10.5, color: col || INK, align: "center", valign: "middle" })); };
  box(0.75, 2.05, 1.65, 0.75, "Project directory", "DDE5EE");
  box(0.75, 3.2, 1.65, 0.75, "Podman secret: single-repo token", "DDE5EE");
  boundary(s, 2.85, 1.9, 2.3, 2.2, TEAL);
  s.addText("Internal network: no route out, no DNS", tb({ x: 2.9, y: 1.97, w: 2.2, h: 0.4, fontSize: 9, bold: true, color: TEAL, align: "center" }));
  box(3.05, 2.45, 1.9, 1.5, [{ text: "Agent container", options: { bold: true, breakLine: true } }, { text: "Claude Code, hooks, MCP", options: { breakLine: true } }, { text: "no capabilities" }], INK, PAPER);
  box(5.45, 2.7, 1.55, 1.0, [{ text: "Proxy", options: { bold: true, breakLine: true } }, { text: "domain allowlist," , options: { breakLine: true } }, { text: "read-only GitHub" }], TEAL, PAPER);
  box(7.65, 2.45, 1.85, 1.5, [{ text: "api.anthropic.com", options: { breakLine: true } }, { text: "github.com", options: { breakLine: true } }, { text: "registries" }], MIST);
  arrow(s, 2.4, 2.78, 0.65, INK); arrow(s, 2.4, 3.63, 0.65, INK); arrow(s, 4.95, 3.23, 0.5, INK); arrow(s, 7.0, 3.2, 0.65, INK);
  s.addText("read-write", tb({ x: 2.35, y: 2.5, w: 0.8, h: 0.2, fontSize: 8.5, color: MUTED, align: "center" }));
  s.addText("GH_TOKEN", tb({ x: 2.35, y: 3.35, w: 0.8, h: 0.2, fontSize: 8.5, color: MUTED, align: "center" }));
  s.addText("HTTPS", tb({ x: 4.95, y: 3.3, w: 0.5, h: 0.2, fontSize: 8.5, color: MUTED, align: "center" }));
  const caps = [
    ["The whole agent is inside", "Hooks and MCP servers too, not just shell commands."],
    ["The only way out is the proxy", "It runs in another container, so the agent cannot change it."],
    ["The token fits one repository", "Attached only in a checkout of that repository."],
  ];
  caps.forEach((c, i) => {
    const x = 0.5 + i * 3.07;
    s.addText(c[0], tb({ x, y: 4.4, w: 2.9, h: 0.27, fontSize: 12, bold: true, color: TEAL }));
    s.addText(c[1], tb({ x, y: 4.67, w: 2.9, h: 0.45, fontSize: 10.5, color: INK }));
  });
  s.addNotes("Two containers. The agent's network is created internal with DNS switched off, so it cannot even resolve an outside name. It reaches the proxy by IP address, and the proxy only allows HTTPS to a short list of domains. The project directory is the only host path mounted; my home directory is simply not there.");
}

// ---------- 12. project: stages and daily use ----------
{
  const s = slide();
  heading(s, "12. Three stages, then one command", "Every piece is a short, commented file you can read.");
  const st = [
    ["1", "Podman", "01-setup-podman.sh", "Rootless Podman, GPU through CDI, agent and proxy images, two internal networks."],
    ["2", "GitHub", "02-github-single-repo.sh", "A fine-grained token for one repository: read, commit, push, comment. Stored as a Podman secret."],
    ["3", "Claude settings", "managed-settings.json", "Baked into the image: a repository's hooks and MCP servers never load. No merge, force-push asks."],
  ];
  st.forEach((r, i) => {
    const x = 0.5 + i * 3.07;
    card(s, x, 1.55, 2.87, 1.95);
    badge(s, x + 0.2, 1.7, r[0], TEAL);
    s.addText(r[1], tb({ x: x + 0.8, y: 1.7, w: 1.95, h: 0.46, fontSize: 16, bold: true, color: INK, valign: "middle" }));
    s.addText(r[2], tb({ x: x + 0.2, y: 2.27, w: 2.5, h: 0.27, fontSize: 10.5, fontFace: "Liberation Mono", color: TEAL }));
    s.addText(r[3], tb({ x: x + 0.2, y: 2.57, w: 2.5, h: 0.9, fontSize: 10.5, color: INK }));
    if (i < 2) arrow(s, x + 2.89, 2.52, 0.16, MUTED);
  });
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.5, y: 3.7, w: 9, h: 1.4, rectRadius: 0.08, fill: { color: INK }, line: { color: INK, width: 0 } });
  s.addText("Daily use", tb({ x: 0.75, y: 3.8, w: 2, h: 0.3, fontSize: 12, bold: true, color: AMBER }));
  s.addText([
    { text: "cd ~/src/myrepo && agent-run.sh", options: { breakLine: true } },
    { text: "agent-run.sh --gpu --perf", options: { breakLine: true } },
    { text: "agent-run.sh --check-token" },
  ], tb({ x: 0.75, y: 4.12, w: 3.9, h: 0.9, fontSize: 11.5, fontFace: "Liberation Mono", color: PAPER }));
  s.addText([
    { text: "Auto permission mode, inside the boundary", options: { breakLine: true } },
    { text: "CUDA on the GPU you are using, real perf counters", options: { breakLine: true } },
    { text: "Proves the token works here and can write nowhere else" },
  ], tb({ x: 4.75, y: 4.12, w: 4.6, h: 0.9, fontSize: 11.5, color: "D5DDE6" }));
  s.addNotes("Setup is three scripts. After that it is one command from any checkout. Inside the boundary I let Claude run in auto mode, because a wrong approval can now only hurt one project directory and one repository. The managed deny and ask rules still apply in auto mode.");
}

// ---------- 13. project: untrusted repos + evidence ----------
{
  const s = slide();
  heading(s, "13. Untrusted repositories, and proof", "Claims in the guide are tested, with controls.");
  s.addText("A repository you have not reviewed", tb({ x: 0.5, y: 1.5, w: 4.5, h: 0.3, fontSize: 14, bold: true, color: INK }));
  s.addText(bullets([
    "inspect-repo.sh clones without running anything and flags hooks, MCP commands, env overrides, folder-open tasks, install scripts, hidden Unicode.",
    "agent-run.sh --untrusted: no token, no GPU, manual approvals, separate state. Network: the model API plus read-only GitHub, enforced by the proxy.",
    "The repository's settings, .mcp.json and CLAUDE.md are not loaded at all.",
    "Git's own back doors are closed: .git/hooks is read-only, and .git/config changes are shown after each session.",
    "For code you consider hostile, use a VM. This shares your kernel.",
  ]), tb({ x: 0.5, y: 1.85, w: 4.6, h: 3.2, fontSize: 11.5, color: INK }));
  const stats = [
    ["3 + 1", "hooks and an MCP server ran in the control run, protections off, with no prompt", RUST],
    ["0", "ran in the sandbox as shipped. Each untrusted-mode layer blocks them on its own", TEAL],
    ["251", "automated checks, including a real setup run and live container tests in CI", INK],
  ];
  stats.forEach((t, i) => {
    const y = 1.5 + i * 1.2;
    card(s, 5.4, y, 4.1, 1.08);
    s.addText(t[0], tb({ x: 5.55, y: y + 0.05, w: 1.35, h: 0.98, fontSize: 32, bold: true, color: t[2], align: "center", valign: "middle" }));
    s.addText(t[1], tb({ x: 6.95, y: y + 0.08, w: 2.45, h: 0.92, fontSize: 10.5, color: INK, valign: "middle" }));
  });
  s.addNotes("The part I am proudest of is that the claims are measured. The hook test builds a hostile repository and runs it with the protections switched off first, to prove the test can see a hook fire. Building the tests found real bugs in my own scripts, including one that would have broken the proxy completely.");
}

// ---------- 14. links ----------
{
  const s = slide();
  heading(s, "14. Further reading", "General guidance on sandboxing agents.");
  const links = [
    ["Claude Code attack surface", "Florian Bruniaux. Model output, hook scripts, MCP servers.", "https://www.florian.bruniaux.com/guides/claude-code-attack-surface/"],
    ["Docker sandboxes aren't enough for agent safety", "Arcade. Solid principles, short on specifics.", "https://www.arcade.dev/blog/docker-sandboxes-arent-enough-for-agent-safety/"],
    ["Claude Code native sandbox guide", "Florian Bruniaux. Configuration, and a comparison with Docker sandboxing.", "https://github.com/FlorianBruniaux/claude-code-ultimate-guide/blob/main/guide/security/sandbox-native.md"],
    ["Choose a sandbox environment", "Anthropic. What each option isolates, and what it does not.", "https://code.claude.com/docs/en/sandbox-environments"],
    ["Practical security guidance for sandboxing agentic workflows", "NVIDIA AI red team. Mandatory and recommended controls.", "https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/"],
    ["The lethal trifecta", "Simon Willison. Private data, untrusted content, external communication.", "https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/"],
    ["GitHub MCP exploited", "Invariant Labs. The attack that motivates single-repository tokens.", "https://invariantlabs.ai/blog/mcp-github-vulnerability"],
    ["NVIDIA OpenShell", "Open-source agent runtime: binary identity, endpoint-bound credentials, request rules.", "https://github.com/NVIDIA/OpenShell"],
  ];
  links.forEach((l, i) => {
    const y = 1.45 + i * 0.47;
    s.addText([{ text: l[0], options: { hyperlink: { url: l[2] }, color: TEAL, bold: true } }], tb({ x: 0.5, y, w: 9, h: 0.24, fontSize: 12 }));
    s.addText(l[1], tb({ x: 0.5, y: y + 0.22, w: 9, h: 0.22, fontSize: 10, color: MUTED }));
  });
  s.addNotes("The first three are where I started. The guide in the repository has a fuller source list, with the advisories for every CVE mentioned in this talk.");
}

// ---------- 15. project link ----------
{
  const s = slide(true);
  boundary(s, 0.5, 0.5, 9, 4.6, TEAL);
  s.addText("The project", tb({ x: 1.0, y: 1.1, w: 8, h: 0.4, fontSize: 16, bold: true, color: AMBER }));
  s.addText([{ text: "github.com/corwinjoy/agent-sandbox", options: { hyperlink: { url: "https://github.com/corwinjoy/agent-sandbox" }, color: PAPER } }], tb({ x: 1.0, y: 1.55, w: 8, h: 0.7, fontSize: 30, bold: true }));
  s.addText(bullets([
    "docs/setup-guide.md: setup and usage",
    "scripts/: setup, daily usage, CI",
    "tests/: static, unit and integration tests",
  ], { color: "D5DDE6" }), tb({ x: 1.0, y: 2.55, w: 7.8, h: 1.3, fontSize: 13, color: "D5DDE6" }));
  s.addText("Boundaries that hold when nobody is watching.", tb({ x: 1.0, y: 4.2, w: 8, h: 0.4, fontSize: 16, italic: true, color: "B8C4D0" }));
  s.addNotes("Tested on Ubuntu 24.04 with Podman 4.9. Issues and fixes are welcome.");
}

pres.writeFile({ fileName: out }).then((f) => console.log("wrote " + f));
