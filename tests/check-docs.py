#!/usr/bin/env python3
"""Check the docs against themselves and against the scripts. Exit 1 on any problem.

  - every #anchor link in the guide and the README points at a real heading
  - every relative file link exists
  - the managed-settings JSON shown in the guide is the file's content
  - the token-URL excerpt in the guide is still in 02-github-single-repo.sh
  - every file under scripts/ is listed in Appendix D
  - every launcher flag is mentioned in the guide
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
problems = []

def slug(h):  # GitHub's heading-to-anchor rule, near enough for ASCII headings
    return re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-")

def read(p):
    with open(os.path.join(ROOT, p)) as f:
        return f.read()

guide, readme = read("docs/setup-guide.md"), read("README.md")
heads = {slug(h) for h in re.findall(r"^#{1,4} (.+)$", guide, flags=re.M)}

for a in set(re.findall(r"\]\(#([^)]+)\)", guide)):
    if a not in heads:
        problems.append(f"BROKEN anchor in guide: #{a}")
for a in set(re.findall(r"\]\(docs/setup-guide\.md#([^)]+)\)", readme)):
    if a not in heads:
        problems.append(f"BROKEN anchor in README: #{a}")
for base, text in (("docs", guide), ("", readme)):
    for l in set(re.findall(r"\]\(((?!https?:|#|mailto:)[^)#]+)(?:#[^)]*)?\)", text)):
        if not os.path.exists(os.path.join(ROOT, base, l)):
            problems.append(f"BROKEN file link: {l}")

managed = json.loads(read("scripts/container/managed-settings.json"))
blocks = re.findall(r"```json\n(.*?)```", guide, flags=re.S)
if not any(json.loads(b) == managed for b in blocks):
    problems.append("MISMATCH: managed-settings.json is not the JSON shown in the guide")

token_script = read("scripts/02-github-single-repo.sh")
m = re.search(r"```bash\n(URL=.*?)```", guide, flags=re.S)
if not m:
    problems.append("MISSING: token URL excerpt in the guide")
else:
    for line in m.group(1).strip().split("\n"):
        if line not in token_script:
            problems.append(f"MISMATCH: guide shows a line that is not in 02-github-single-repo.sh: {line}")

appendix_d = guide.split("## Appendix D")[1].split("\n## ")[0]
for d, _, files in os.walk(os.path.join(ROOT, "scripts")):
    for f in files:
        rel = os.path.relpath(os.path.join(d, f), os.path.join(ROOT, "scripts"))
        if f"`{rel}`" not in appendix_d:
            problems.append(f"MISSING from Appendix D: {rel}")

launcher = read("scripts/agent-run.sh")
for flag in sorted(set(re.findall(r"(--[a-z][a-z-]+)\)", launcher.split("while [ $# -gt 0 ]")[1].split("done")[0]))):
    if flag != "--help" and f"`{flag}`" not in guide:
        problems.append(f"MISSING from the guide: launcher flag {flag}")

for p in problems:
    print(p)
print(f"check-docs: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
