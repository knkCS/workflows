#!/usr/bin/env python3
"""Render every ArgoCD Application an ApplicationSet generates, with its real
value files, then schema-validate the rendered manifests with kubeconform.

Engine behind the argocd-rendering-check reusable workflow
(.github/workflows/argocd-rendering-check.yml). A deploy repo's CI calls the
workflow; the workflow runs this script against the caller's checkout. The
self-test (tests/rendering-check/run.sh) runs it against committed fixtures.

The three source shapes it renders are knkcms/deploy's
(argocd/applicationsets/*.yaml there is the canonical consumer):

  1. a chart in a service repo's git source (`repoURL: ...git` + `path:`),
     values fed from the deploy repo through a `$ref/` prefix — the ref source
     naming the repo under test resolves to the LOCAL CHECKOUT, whatever its
     targetRevision pins, because CI must render the tree the PR proposes;
  2. an upstream Helm-repository chart (`chart:` + repoURL). A repoURL with an
     http(s) scheme is a classic Helm repository; one WITHOUT a scheme is an
     OCI registry in ArgoCD's spelling (ArgoCD adds oci:// itself; the helm
     CLI wants it explicit, so this script adds it back);
  3. a chart held in the deploy repo itself (`path: charts/...`).

A source with only `ref:` renders nothing (it anchors value files). A
directory source renders no chart either: the YAML files it syncs are
collected into the schema-validation set instead.

Generators supported: `list`, and `matrix` over nested list/matrix. Anything
else (git, cluster, ...) fails loudly rather than silently rendering nothing.
Placeholders that survive substitution fail for the same reason.

Applications whose `environment` generator parameter is in --skip-env are
skipped — that is the knob for environments a deploy repo declares unwired.

Exit codes: 0 all rendered and validated; 1 render or validation failures
(bad references, missing value files, invalid YAML, invalid manifests);
2 usage or environment problems (missing tools, missing --repo-root/argocd-dir).
"""

import argparse
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:  # pragma: no cover
    print("FATAL: PyYAML is required (python3 -m pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

PLACEHOLDER = re.compile(r"\{\{\s*([\w.-]+)\s*\}\}")


def log(msg):
    print(msg, flush=True)


def gha_error(msg):
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error::{msg}", flush=True)


class RenderError(Exception):
    pass


def normalize_repo_url(url):
    """Compare repo URLs scheme- and suffix-insensitively.

    https://github.com/Org/Repo.git, github.com/org/repo and
    git@github.com:org/repo all normalize to github.com/org/repo.
    """
    u = url.strip().lower()
    u = re.sub(r"^(https?|oci|ssh)://", "", u)
    u = re.sub(r"^git@([^:]+):", r"\1/", u)
    u = u.rstrip("/")
    if u.endswith(".git"):
        u = u[: -len(".git")]
    return u


def substitute(obj, params):
    """ArgoCD fasttemplate-style {{param}} substitution over a YAML tree."""
    if isinstance(obj, dict):
        return {substitute(k, params): substitute(v, params) for k, v in obj.items()}
    if isinstance(obj, list):
        return [substitute(v, params) for v in obj]
    if isinstance(obj, str):
        return PLACEHOLDER.sub(
            lambda m: str(params[m.group(1)]) if m.group(1) in params else m.group(0),
            obj,
        )
    return obj


def find_unresolved(obj, at=""):
    found = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            found += find_unresolved(v, f"{at}.{k}" if at else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            found += find_unresolved(v, f"{at}[{i}]")
    elif isinstance(obj, str):
        for m in PLACEHOLDER.finditer(obj):
            found.append(f"{at}: {{{{{m.group(1)}}}}}")
    return found


def expand_generators(generators, source_desc):
    """Expand a generators list to concrete parameter dicts (union of entries)."""
    params = []
    for gen in generators:
        if not isinstance(gen, dict):
            raise RenderError(f"{source_desc}: generator entry is not a mapping")
        if "list" in gen:
            elements = gen["list"].get("elements", [])
            for el in elements:
                if not isinstance(el, dict):
                    raise RenderError(f"{source_desc}: list generator element is not a mapping")
                params.append(dict(el))
        elif "matrix" in gen:
            children = gen["matrix"].get("generators", [])
            if not children:
                raise RenderError(f"{source_desc}: matrix generator has no child generators")
            combos = [{}]
            for child in children:
                child_params = expand_generators([child], source_desc)
                combos = [{**a, **b} for a in combos for b in child_params]
            params.extend(combos)
        else:
            kinds = ", ".join(sorted(gen)) or "(empty)"
            raise RenderError(
                f"{source_desc}: unsupported generator type '{kinds}' — "
                "only list and matrix-over-list are rendered"
            )
    return params


class Renderer:
    def __init__(self, args):
        self.repo_root = os.path.realpath(args.repo_root)
        self.self_urls = {normalize_repo_url(u) for u in args.repo_url}
        self.skip_envs = {e.strip() for e in re.split(r"[,\s]+", args.skip_env) if e.strip()}
        self.kube_version = args.kubernetes_version
        self.kubeconform_flags = shlex.split(args.kubeconform_flags)
        self.out_dir = args.output_dir
        self.work_dir = tempfile.mkdtemp(prefix="argocd-render-")
        self.clone_cache = {}
        self.chart_cache = {}
        self.errors = []
        self.rendered = []       # app names with helm output
        self.collected = []      # app names with directory-source output
        self.skipped = []
        self.seen_names = {}

    # -- repo / chart resolution --------------------------------------------

    def error(self, msg):
        self.errors.append(msg)
        print(f"ERROR: {msg}", file=sys.stderr, flush=True)
        gha_error(msg)

    def run_cmd(self, cmd, **kw):
        return subprocess.run(cmd, capture_output=True, text=True, **kw)

    def resolve_repo(self, url, revision, why):
        """A git repoURL -> local directory. The repo under test is its checkout."""
        if normalize_repo_url(url) in self.self_urls:
            return self.repo_root
        key = f"{normalize_repo_url(url)}@{revision}"
        if key in self.clone_cache:
            return self.clone_cache[key]
        dst = os.path.join(
            self.work_dir, "repos", hashlib.sha1(key.encode()).hexdigest()[:16]
        )
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        log(f"  clone {url} @ {revision} ({why})")
        if revision in ("", "HEAD", None):
            proc = self.run_cmd(["git", "clone", "--quiet", "--depth", "1", url, dst])
        else:
            proc = self.run_cmd(
                ["git", "clone", "--quiet", "--depth", "1", "--branch", str(revision), url, dst]
            )
            if proc.returncode != 0 and re.fullmatch(r"[0-9a-f]{7,40}", str(revision)):
                # A pinned commit: not clonable by --branch, fetch it directly.
                os.makedirs(dst, exist_ok=True)
                for cmd in (
                    ["git", "-C", dst, "init", "--quiet"],
                    ["git", "-C", dst, "remote", "add", "origin", url],
                    ["git", "-C", dst, "fetch", "--quiet", "--depth", "1", "origin", str(revision)],
                    ["git", "-C", dst, "checkout", "--quiet", "FETCH_HEAD"],
                ):
                    proc = self.run_cmd(cmd)
                    if proc.returncode != 0:
                        break
        if proc.returncode != 0:
            raise RenderError(
                f"cannot fetch {url} @ {revision}: {proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else 'git failed'}"
            )
        self.clone_cache[key] = dst
        return dst

    def resolve_helm_chart(self, repo_url, chart, version):
        """A Helm-repository or OCI chart -> untarred local chart directory."""
        key = f"{repo_url}|{chart}|{version}"
        if key in self.chart_cache:
            return self.chart_cache[key]
        dst = os.path.join(
            self.work_dir, "charts", hashlib.sha1(key.encode()).hexdigest()[:16]
        )
        os.makedirs(dst, exist_ok=True)
        if re.match(r"^https?://", repo_url):
            cmd = ["helm", "pull", chart, "--repo", repo_url,
                   "--version", str(version), "--untar", "--untardir", dst]
            log(f"  pull {chart} {version} from helm repo {repo_url}")
        else:
            # ArgoCD spells OCI registries schemeless; the helm CLI wants oci://.
            oci = f"oci://{repo_url.rstrip('/')}/{chart}"
            cmd = ["helm", "pull", oci, "--version", str(version), "--untar", "--untardir", dst]
            log(f"  pull {oci} {version}")
        proc = self.run_cmd(cmd)
        if proc.returncode != 0:
            raise RenderError(
                f"helm pull failed for chart '{chart}' {version} from {repo_url}: "
                f"{proc.stderr.strip()}"
            )
        chart_dir = os.path.join(dst, chart)
        if not os.path.isdir(chart_dir):
            entries = [e for e in os.listdir(dst) if os.path.isdir(os.path.join(dst, e))]
            if len(entries) == 1:
                chart_dir = os.path.join(dst, entries[0])
            else:
                raise RenderError(f"pulled chart '{chart}' did not untar where expected ({dst})")
        self.chart_cache[key] = chart_dir
        return chart_dir

    def ensure_within(self, root, path, what):
        root = os.path.realpath(root)
        if path != root and not path.startswith(root + os.sep):
            raise RenderError(f"{what} escapes its repository")
        return path

    def contained_path(self, root, rel, what):
        p = os.path.realpath(os.path.join(root, rel))
        return self.ensure_within(root, p, f"{what} '{rel}'")

    # -- value files --------------------------------------------------------

    def resolve_value_files(self, app_name, helm_cfg, refs, chart_repo_dir, chart_dir):
        """valueFiles entries -> local paths. $ref/... resolves through the named
        ref source's repo; a plain relative path resolves against the source's
        `path` (the chart directory), as ArgoCD resolves it — `..` may climb
        within the source's repo but never out of it."""
        files = []
        ignore_missing = bool(helm_cfg.get("ignoreMissingValueFiles"))
        for vf in helm_cfg.get("valueFiles", []) or []:
            if vf.startswith("$"):
                ref_name, _, rel = vf[1:].partition("/")
                if not rel or ref_name not in refs:
                    raise RenderError(
                        f"{app_name}: value file '{vf}' names ref '{ref_name}' "
                        f"but no source declares it"
                    )
                ref_src = refs[ref_name]
                repo_dir = self.resolve_repo(
                    ref_src.get("repoURL", ""), ref_src.get("targetRevision", "HEAD"),
                    f"values ref ${ref_name}",
                )
                path = self.contained_path(repo_dir, rel, f"{app_name}: value file")
            else:
                containment = chart_dir if chart_repo_dir is None else chart_repo_dir
                path = os.path.realpath(os.path.join(chart_dir, vf))
                self.ensure_within(containment, path, f"{app_name}: value file '{vf}'")
            if not os.path.isfile(path):
                shown = vf if vf.startswith("$") else os.path.relpath(path, self.repo_root)
                if ignore_missing:
                    log(f"  {app_name}: value file {shown} absent, ignoreMissingValueFiles is set")
                    continue
                raise RenderError(f"{app_name}: missing value file: {shown}")
            files.append(path)
        return files

    # -- application rendering ----------------------------------------------

    def render_app(self, app_name, spec, source_file):
        sources = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
        if not sources:
            raise RenderError(f"{app_name}: no source declared")
        refs = {s["ref"]: s for s in sources if isinstance(s, dict) and s.get("ref")}
        namespace = (spec.get("destination") or {}).get("namespace")
        outputs = []

        for src in sources:
            if not isinstance(src, dict):
                raise RenderError(f"{app_name}: source is not a mapping")
            if "chart" in src and "path" in src:
                raise RenderError(f"{app_name}: source declares both chart and path")

            if "chart" in src:
                chart_dir = self.resolve_helm_chart(
                    src.get("repoURL", ""), src["chart"], src.get("targetRevision", "")
                )
                chart_repo_dir = None
            elif "path" in src:
                repo_dir = self.resolve_repo(
                    src.get("repoURL", ""), src.get("targetRevision", "HEAD"),
                    f"chart source of {app_name}",
                )
                chart_dir = self.contained_path(repo_dir, src["path"], f"{app_name}: path")
                chart_repo_dir = repo_dir
                if not os.path.isdir(chart_dir):
                    raise RenderError(
                        f"{app_name}: path '{src['path']}' does not exist in "
                        f"{src.get('repoURL', '')} @ {src.get('targetRevision', 'HEAD')}"
                    )
                has_chart = os.path.isfile(os.path.join(chart_dir, "Chart.yaml"))
                if not has_chart:
                    if "helm" in src:
                        raise RenderError(
                            f"{app_name}: path '{src['path']}' has a helm config "
                            f"but no Chart.yaml in {src.get('repoURL', '')}"
                        )
                    outputs.append(self.collect_directory(app_name, src, chart_dir))
                    continue
            else:
                continue  # bare ref source: value-files anchor only

            helm_cfg = src.get("helm") or {}
            values = self.resolve_value_files(
                app_name, helm_cfg, refs, chart_repo_dir, chart_dir
            )
            outputs.append(
                self.helm_template(app_name, chart_dir, namespace, helm_cfg, values)
            )

        rendered = [o for o in outputs if o]
        if not rendered:
            log(f"  {app_name}: nothing to render (no chart or directory source)")
            return
        out_file = os.path.join(self.out_dir, f"{app_name}.yaml")
        with open(out_file, "w") as f:
            f.write("\n---\n".join(rendered))
        return out_file

    def helm_template(self, app_name, chart_dir, namespace, helm_cfg, value_files):
        chart_meta = {}
        with open(os.path.join(chart_dir, "Chart.yaml")) as f:
            chart_meta = yaml.safe_load(f) or {}
        if chart_meta.get("dependencies") and not os.path.isdir(os.path.join(chart_dir, "charts")):
            proc = self.run_cmd(["helm", "dependency", "build", chart_dir])
            if proc.returncode != 0:
                proc = self.run_cmd(["helm", "dependency", "update", chart_dir])
                if proc.returncode != 0:
                    raise RenderError(
                        f"{app_name}: helm dependency build failed: {proc.stderr.strip()}"
                    )

        release = helm_cfg.get("releaseName") or app_name
        cmd = ["helm", "template", release, chart_dir,
               "--kube-version", self.kube_version, "--include-crds"]
        if namespace:
            cmd += ["--namespace", namespace]
        for vf in value_files:
            cmd += ["-f", vf]
        inline = helm_cfg.get("valuesObject") or helm_cfg.get("values")
        if inline:
            if isinstance(inline, str):
                inline = yaml.safe_load(inline)
            inline_file = os.path.join(self.work_dir, f"{hashlib.sha1(app_name.encode()).hexdigest()[:12]}-inline.yaml")
            with open(inline_file, "w") as f:
                yaml.safe_dump(inline, f)
            cmd += ["-f", inline_file]
        for p in helm_cfg.get("parameters", []) or []:
            flag = "--set-string" if p.get("forceString") else "--set"
            cmd += [flag, f"{p.get('name')}={p.get('value')}"]
        proc = self.run_cmd(cmd)
        if proc.returncode != 0:
            raise RenderError(
                f"{app_name}: helm template failed:\n{proc.stderr.strip()}"
            )
        self.rendered.append(app_name)
        log(f"  {app_name}: rendered ({os.path.basename(chart_dir)}, "
            f"{len(value_files)} value file(s))")
        return proc.stdout

    def collect_directory(self, app_name, src, dir_path):
        """A directory source syncs raw YAML; feed those files to validation."""
        recurse = bool((src.get("directory") or {}).get("recurse"))
        docs = []
        if recurse:
            for root, _, names in os.walk(dir_path):
                for n in sorted(names):
                    if n.endswith((".yaml", ".yml")):
                        docs.append(os.path.join(root, n))
        else:
            docs = sorted(
                os.path.join(dir_path, n)
                for n in os.listdir(dir_path)
                if n.endswith((".yaml", ".yml"))
            )
        parts = []
        for d in docs:
            with open(d) as f:
                parts.append(f.read())
        self.collected.append(app_name)
        log(f"  {app_name}: directory source, collected {len(docs)} file(s) for validation")
        return "\n---\n".join(parts)

    # -- document walk ------------------------------------------------------

    def app_docs(self, argocd_dir):
        found = []
        for root, _, names in os.walk(argocd_dir):
            for n in sorted(names):
                if not n.endswith((".yaml", ".yml")):
                    continue
                path = os.path.join(root, n)
                try:
                    with open(path) as f:
                        for doc in yaml.safe_load_all(f):
                            if isinstance(doc, dict) and doc.get("kind") in (
                                "Application", "ApplicationSet",
                            ):
                                found.append((path, doc))
                except yaml.YAMLError as e:
                    raise RenderError(f"{path}: not valid YAML: {e}")
        return found

    def generated_apps(self, path, doc):
        """One (file, doc) -> [(app_name, params, spec)]."""
        rel = os.path.relpath(path, self.repo_root)
        if doc["kind"] == "Application":
            name = (doc.get("metadata") or {}).get("name") or rel
            return [(name, {}, doc.get("spec") or {})]
        spec = doc.get("spec") or {}
        template = spec.get("template") or {}
        apps = []
        for params in expand_generators(spec.get("generators", []) or [], rel):
            inst = substitute(template, params)
            unresolved = find_unresolved(inst)
            if unresolved:
                raise RenderError(
                    f"{rel}: unresolved placeholders after substitution: "
                    + "; ".join(unresolved)
                )
            name = (inst.get("metadata") or {}).get("name")
            if not name:
                raise RenderError(f"{rel}: generated Application has no metadata.name")
            apps.append((name, params, inst.get("spec") or {}))
        return apps

    # -- top level -----------------------------------------------------------

    def render_all(self, argocd_dir):
        docs = self.app_docs(argocd_dir)
        if not docs:
            raise RenderError(
                f"no Application or ApplicationSet documents under "
                f"{os.path.relpath(argocd_dir, self.repo_root)} — wrong argocd-dir?"
            )
        for path, doc in docs:
            rel = os.path.relpath(path, self.repo_root)
            kind = doc["kind"]
            name = (doc.get("metadata") or {}).get("name", "?")
            log(f"{rel}: {kind} {name}")
            try:
                apps = self.generated_apps(path, doc)
            except RenderError as e:
                self.error(str(e))
                continue
            for app_name, params, spec in apps:
                env = params.get("environment")
                if env and env in self.skip_envs:
                    self.skipped.append(app_name)
                    log(f"  {app_name}: skipped (environment '{env}')")
                    continue
                if app_name in self.seen_names:
                    self.error(
                        f"duplicate Application name '{app_name}' "
                        f"(also generated by {self.seen_names[app_name]})"
                    )
                    continue
                self.seen_names[app_name] = rel
                try:
                    self.render_app(app_name, spec, rel)
                except RenderError as e:
                    self.error(str(e))

    def validate(self):
        files = sorted(
            os.path.join(self.out_dir, n)
            for n in os.listdir(self.out_dir)
            if n.endswith(".yaml")
        )
        if not files:
            log("nothing rendered — skipping kubeconform")
            return True
        cmd = (
            ["kubeconform"]
            + self.kubeconform_flags
            + ["-summary", "-kubernetes-version", self.kube_version]
            + files
        )
        log("kubeconform: " + " ".join(cmd[: len(cmd) - len(files)]) + f" <{len(files)} file(s)>")
        proc = subprocess.run(cmd)
        if proc.returncode != 0:
            self.error("kubeconform found invalid manifests (its report is above)")
            return False
        return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--repo-root", required=True,
                    help="checkout of the deploy repo under test")
    ap.add_argument("--repo-url", action="append", default=[],
                    help="canonical URL(s) of that repo; sources naming it "
                         "resolve to --repo-root instead of being cloned "
                         "(repeatable)")
    ap.add_argument("--argocd-dir", default="argocd",
                    help="directory (relative to --repo-root) scanned for "
                         "Application/ApplicationSet documents (default: argocd)")
    ap.add_argument("--skip-env", default="",
                    help="comma- or space-separated environments to skip "
                         "(matches the 'environment' generator parameter)")
    ap.add_argument("--kubernetes-version", default="1.31.0",
                    help="passed to helm --kube-version and kubeconform "
                         "-kubernetes-version (default: 1.31.0)")
    ap.add_argument("--kubeconform-flags", default="-strict -ignore-missing-schemas",
                    help="extra kubeconform flags "
                         "(default: '-strict -ignore-missing-schemas')")
    ap.add_argument("--output-dir", default="",
                    help="keep rendered manifests here (default: a temp dir)")
    args = ap.parse_args()

    for tool in ("helm", "git", "kubeconform"):
        if not shutil.which(tool):
            print(f"FATAL: {tool} not on PATH", file=sys.stderr)
            return 2
    if not os.path.isdir(args.repo_root):
        print(f"FATAL: --repo-root {args.repo_root} is not a directory", file=sys.stderr)
        return 2
    argocd_dir = os.path.join(os.path.realpath(args.repo_root), args.argocd_dir)
    if not os.path.isdir(argocd_dir):
        print(f"FATAL: {args.argocd_dir} not found under {args.repo_root}", file=sys.stderr)
        return 2
    args.output_dir = args.output_dir or tempfile.mkdtemp(prefix="argocd-rendered-")
    os.makedirs(args.output_dir, exist_ok=True)

    r = Renderer(args)
    try:
        r.render_all(argocd_dir)
    except RenderError as e:
        r.error(str(e))
    ok = r.validate() and not r.errors

    log(
        f"rendered {len(r.rendered)} application(s), "
        f"collected {len(r.collected)} directory application(s), "
        f"skipped {len(r.skipped)} by environment filter"
    )
    if r.rendered or r.collected:
        log(f"rendered manifests kept in {args.output_dir}")
    if not ok:
        summary = f"rendering check failed with {len(r.errors)} error(s)"
        print(f"ERROR: {summary}", file=sys.stderr)
        gha_error(summary)
        return 1
    log("rendering check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
