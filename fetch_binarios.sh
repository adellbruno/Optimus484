#!/usr/bin/env bash
# Baixa o llama.cpp (llama-server) e o Git portátil e deixa tudo dentro da extensão optimus-agente,
# para o instalador já sair com os dois embutidos.
#
# Uso:   optimus/fetch_binarios.sh <windows|linux> <pasta-bin-da-extensão>
# Opções por variável de ambiente (todas opcionais):
#   LLAMA_TAG      versão do llama.cpp (ex.: b6000). Vazio = a mais recente.
#   GIT_TAG        versão do Git for Windows (ex.: v2.47.1.windows.1). Vazio = a mais recente.
#   INCLUIR_CUDA   "sim" (padrão) ou "nao". Só Windows; o pacote CUDA pesa algumas centenas de MB.
#   INCLUIR_FERRAMENTAS  "sim" (padrão) ou "nao". Só Windows: Node, Python (+PyInstaller), Zig (compilador C/C++) e GitHub CLI.
#   GITHUB_TOKEN   usado só para a API do GitHub não limitar os pedidos.
#
# Resultado:
#   <bin>/llama.cpp/cuda     (Windows, se INCLUIR_CUDA=sim)  llama-server.exe + DLLs do CUDA
#   <bin>/llama.cpp/vulkan   (Windows e Linux)               serve para NVIDIA, AMD e Intel; cai para CPU
#   <bin>/llama.cpp/cpu      (Linux)                         só processador
#   <bin>/git                (Windows)                       MinGit (git.exe em cmd/)
#   <bin>/ferramentas/{node,python,zig,gh}   (Windows) para o agente compilar projetos e criar executáveis
#   <bin>/VERSOES.txt        o que foi embutido
set -euo pipefail

SO="${1:-}"
BIN="${2:-}"
if [[ "$SO" != "windows" && "$SO" != "linux" ]] || [[ -z "$BIN" ]]; then
  echo "Uso: $0 <windows|linux> <pasta-bin>" >&2
  exit 2
fi
INCLUIR_CUDA="${INCLUIR_CUDA:-sim}"
INCLUIR_FERRAMENTAS="${INCLUIR_FERRAMENTAS:-sim}"
if [[ "$SO" == "windows" ]]; then PY="$(command -v python || command -v python3)"; else PY="$(command -v python3 || command -v python)"; fi
API_BASE="${GITHUB_API:-https://api.github.com}"   # só muda nos testes
# No Windows o bash (Git Bash) usa caminhos /d/a/...; o Python nativo precisa do formato D:/a/...
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN"
BIN="$(cd "$BIN" && pwd)"

api() {
  curl -fsSL --retry 5 --retry-delay 3 -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$1"
}

# release_json <repo> <tag-ou-vazio> <arquivo-saida>
release_json() {
  local url="$API_BASE/repos/$1/releases/latest"
  [[ -n "$2" ]] && url="$API_BASE/repos/$1/releases/tags/$2"
  api "$url" > "$3"
}

# escolher <release.json> <regex> [prefere-maior-versao-numerica]  -> imprime "nome<TAB>url"
escolher() {
  "$PY" - "$(wp "$1")" "$2" <<'PYEOF'
import json, re, sys
rel = json.load(open(sys.argv[1], encoding="utf-8"))
rx = re.compile(sys.argv[2])
achados = [a for a in rel.get("assets", []) if rx.search(a["name"])]
if not achados:
    sys.exit(3)
# desempate: maior número de versão no nome (ex.: cuda-12.9 antes de cuda-12.4)
def chave(a):
    return [int(x) for x in re.findall(r"\d+", re.sub(r"^llama-b\d+", "", a["name"]))]
achados.sort(key=chave, reverse=True)
a = achados[0]
print(a["name"] + "\t" + a["browser_download_url"])
PYEOF
}

# baixar_e_extrair <nome> <url> <destino>
baixar_e_extrair() {
  local nome="$1" url="$2" destino="$3"
  echo "  baixando $nome"
  curl -fL --retry 5 --retry-delay 5 -o "$TMP/$nome" "$url"
  echo "  $(du -h "$TMP/$nome" | cut -f1)  ->  $destino"
  mkdir -p "$destino"
  "$PY" - "$(wp "$TMP/$nome")" "$(wp "$destino")" <<'PYEOF'
import sys, tarfile, zipfile
arq, dest = sys.argv[1], sys.argv[2]
if arq.endswith(".zip"):
    with zipfile.ZipFile(arq) as z:
        bad = z.testzip()
        if bad:
            sys.exit("zip corrompido: " + bad)
        z.extractall(dest)
else:
    with tarfile.open(arq) as t:
        t.extractall(dest)
PYEOF
  rm -f "$TMP/$nome"
}

# Os pacotes às vezes vêm numa subpasta; sobe o conteúdo para a raiz da variante.
achatar() {
  local d="$1"
  local exe="llama-server"; [[ "$SO" == "windows" ]] && exe="llama-server.exe"
  if [[ ! -f "$d/$exe" ]]; then
    local achado
    achado="$(find "$d" -name "$exe" -type f | head -n1 || true)"
    [[ -n "$achado" ]] || { echo "ERRO: $exe não encontrado em $d" >&2; exit 1; }
    local pai; pai="$(dirname "$achado")"
    if [[ "$pai" != "$d" ]]; then
      cp -a "$pai"/. "$d"/
      find "$d" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
    fi
  fi
  [[ -f "$d/$exe" ]] || { echo "ERRO: $exe não ficou em $d" >&2; exit 1; }
  [[ "$SO" == "linux" ]] && chmod +x "$d"/llama-* 2>/dev/null || true
}

: > "$BIN/VERSOES.txt"
rm -rf "$BIN/llama.cpp" "$BIN/git" "$BIN/ferramentas"

# ---------------------------------------------------------------- llama.cpp
echo "== llama.cpp =="
release_json "ggml-org/llama.cpp" "${LLAMA_TAG:-}" "$TMP/llama.json"
LLAMA_VER="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['tag_name'])" "$(wp "$TMP/llama.json")")"
echo "versão: $LLAMA_VER"
echo "llama.cpp $LLAMA_VER" >> "$BIN/VERSOES.txt"

if [[ "$SO" == "windows" ]]; then
  if [[ "$INCLUIR_CUDA" == "sim" ]]; then
    IFS=$'\t' read -r N U < <(escolher "$TMP/llama.json" '^llama-.*-bin-win-cuda-12\.[0-9]+-x64\.zip$') \
      || { echo "ERRO: pacote CUDA 12 do llama.cpp não encontrado em $LLAMA_VER" >&2; exit 1; }
    baixar_e_extrair "$N" "$U" "$BIN/llama.cpp/cuda"
    # as DLLs do runtime do CUDA vêm num pacote separado; o usuário não precisa instalar o CUDA
    IFS=$'\t' read -r N U < <(escolher "$TMP/llama.json" '^cudart-llama-bin-win-cuda-12\.[0-9]+-x64\.zip$') \
      || { echo "ERRO: pacote cudart do llama.cpp não encontrado em $LLAMA_VER" >&2; exit 1; }
    baixar_e_extrair "$N" "$U" "$BIN/llama.cpp/cuda"
    achatar "$BIN/llama.cpp/cuda"
    echo "  variante cuda: $N" >> "$BIN/VERSOES.txt"
  fi
  IFS=$'\t' read -r N U < <(escolher "$TMP/llama.json" '^llama-.*-bin-win-vulkan-x64\.zip$') \
    || { echo "ERRO: pacote Vulkan do llama.cpp não encontrado em $LLAMA_VER" >&2; exit 1; }
  baixar_e_extrair "$N" "$U" "$BIN/llama.cpp/vulkan"
  achatar "$BIN/llama.cpp/vulkan"
else
  IFS=$'\t' read -r N U < <(escolher "$TMP/llama.json" '^llama-.*-bin-ubuntu-vulkan-x64\.tar\.gz$') \
    || { echo "AVISO: pacote Vulkan para Linux não encontrado; seguindo só com CPU" >&2; N=""; U=""; }
  if [[ -n "${N:-}" ]]; then
    baixar_e_extrair "$N" "$U" "$BIN/llama.cpp/vulkan"
    achatar "$BIN/llama.cpp/vulkan"
  fi
  IFS=$'\t' read -r N U < <(escolher "$TMP/llama.json" '^llama-.*-bin-ubuntu-x64\.tar\.gz$') \
    || { echo "ERRO: pacote CPU para Linux do llama.cpp não encontrado em $LLAMA_VER" >&2; exit 1; }
  baixar_e_extrair "$N" "$U" "$BIN/llama.cpp/cpu"
  achatar "$BIN/llama.cpp/cpu"
fi

# ---------------------------------------------------------------- git (só Windows)
if [[ "$SO" == "windows" ]]; then
  echo "== Git (MinGit) =="
  release_json "git-for-windows/git" "${GIT_TAG:-}" "$TMP/git.json"
  IFS=$'\t' read -r N U < <(escolher "$TMP/git.json" '^MinGit-[0-9.]+-64-bit\.zip$') \
    || { echo "ERRO: MinGit 64 bits não encontrado" >&2; exit 1; }
  baixar_e_extrair "$N" "$U" "$BIN/git"
  [[ -f "$BIN/git/cmd/git.exe" ]] || { echo "ERRO: git.exe não ficou em $BIN/git/cmd" >&2; exit 1; }
  echo "$N" >> "$BIN/VERSOES.txt"
  [[ "${FERRAMENTAS_TESTE:-}" == "1" ]] || "$BIN/git/cmd/git.exe" --version
fi

# ---------------------------------------------------------------- ferramentas de build (só Windows)
# sobe o conteúdo de uma pasta que só tem uma subpasta (ex.: node-v22-win-x64/)
subir_unico() {
  local d="$1" n u
  n="$(find "$d" -mindepth 1 -maxdepth 1 | wc -l)"
  if [[ "$n" == "1" ]]; then
    u="$(find "$d" -mindepth 1 -maxdepth 1 -type d)"
    if [[ -n "$u" ]]; then
      mv "$u"/* "$d"/ 2>/dev/null || true
      mv "$u"/.[!.]* "$d"/ 2>/dev/null || true
      rmdir "$u" 2>/dev/null || true
    fi
  fi
}

# confere que o programa roda (no teste local, FERRAMENTAS_TESTE=1, só confere que o arquivo existe)
conferir() {
  local rotulo="$1"; shift
  [[ -f "$1" ]] || { echo "ERRO: $rotulo: arquivo $1 não encontrado" >&2; exit 1; }
  if [[ "${FERRAMENTAS_TESTE:-}" == "1" ]]; then echo "  ok  $rotulo (só existência)"; return; fi
  local v; v="$("$@" 2>&1 | head -n1)" || { echo "ERRO: $rotulo não executa" >&2; exit 1; }
  echo "  ok  $rotulo: $v"; echo "  $rotulo: $v" >> "$BIN/VERSOES.txt"
}

if [[ "$SO" == "windows" && "$INCLUIR_FERRAMENTAS" == "sim" ]]; then
  F="$BIN/ferramentas"
  mkdir -p "$F"

  echo "== Node.js =="
  curl -fsSL --retry 5 --retry-delay 3 "${NODE_INDEX:-https://nodejs.org/dist/index.json}" -o "$TMP/node.json"
  NODE_URL="$("$PY" - "$(wp "$TMP/node.json")" "${NODE_DIST:-https://nodejs.org/dist}" <<'PYEOF'
import json, sys
for e in json.load(open(sys.argv[1], encoding="utf-8")):
    if e.get("lts") and "win-x64-zip" in e.get("files", []):
        print("%s/%s/node-%s-win-x64.zip" % (sys.argv[2] if len(sys.argv) > 2 else "https://nodejs.org/dist", e["version"], e["version"]))
        break
PYEOF
)"
  [[ -n "$NODE_URL" ]] || { echo "ERRO: Node LTS para Windows não encontrado" >&2; exit 1; }
  baixar_e_extrair "$(basename "$NODE_URL")" "$NODE_URL" "$F/node"; subir_unico "$F/node"
  conferir "node" "$F/node/node.exe" --version

  echo "== Python (+ PyInstaller) =="
  release_json "astral-sh/python-build-standalone" "" "$TMP/py.json"
  IFS=$'\t' read -r N U < <(escolher "$TMP/py.json" '^cpython-3\.12\.[0-9]+\+[0-9]+-x86_64-pc-windows-msvc-install_only\.tar\.gz$') \
    || { echo "ERRO: Python 3.12 (python-build-standalone) não encontrado" >&2; exit 1; }
  baixar_e_extrair "$N" "$U" "$F/python"; subir_unico "$F/python"
  conferir "python" "$F/python/python.exe" --version
  if [[ "${FERRAMENTAS_TESTE:-}" != "1" ]]; then
    "$F/python/python.exe" -m pip install --no-warn-script-location --disable-pip-version-check pyinstaller
    conferir "pyinstaller" "$F/python/Scripts/pyinstaller.exe" --version
  fi

  echo "== Zig (compilador C/C++) =="
  curl -fsSL --retry 5 --retry-delay 3 "${ZIG_INDEX:-https://ziglang.org/download/index.json}" -o "$TMP/zig.json"
  ZIG_URL="$("$PY" - "$(wp "$TMP/zig.json")" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
vs = [k for k in d if re.fullmatch(r"\d+\.\d+\.\d+", k) and "x86_64-windows" in d[k]]
vs.sort(key=lambda v: [int(x) for x in v.split(".")], reverse=True)
if vs:
    print(d[vs[0]]["x86_64-windows"]["tarball"])
PYEOF
)"
  [[ -n "$ZIG_URL" ]] || { echo "ERRO: Zig para Windows não encontrado" >&2; exit 1; }
  baixar_e_extrair "$(basename "$ZIG_URL")" "$ZIG_URL" "$F/zig"; subir_unico "$F/zig"
  conferir "zig" "$F/zig/zig.exe" version

  echo "== GitHub CLI =="
  release_json "cli/cli" "" "$TMP/gh.json"
  IFS=$'\t' read -r N U < <(escolher "$TMP/gh.json" '^gh_[0-9.]+_windows_amd64\.zip$') \
    || { echo "ERRO: GitHub CLI para Windows não encontrado" >&2; exit 1; }
  baixar_e_extrair "$N" "$U" "$F/gh"
  conferir "gh" "$F/gh/bin/gh.exe" --version
  du -sh "$F"/* 2>/dev/null || true
fi

# ---------------------------------------------------------------- verificação
echo "== Verificação =="
for d in "$BIN"/llama.cpp/*/; do
  exe="$d/llama-server"; [[ "$SO" == "windows" ]] && exe="$d/llama-server.exe"
  [[ -f "$exe" ]] || { echo "ERRO: falta $exe" >&2; exit 1; }
  # --version carrega os backends; numa máquina sem GPU/driver (como o runner) o CUDA/Vulkan pode reclamar.
  if "$exe" --version >/dev/null 2>&1; then
    echo "  OK  $(basename "$d")"
  elif [[ "$SO" == "linux" && "$(basename "$d")" == "cpu" ]]; then
    echo "ERRO: llama-server (cpu) não executa neste sistema" >&2; exit 1
  else
    echo "  aviso: $(basename "$d") não executou aqui (provável falta de GPU/driver no runner); arquivos conferidos"
  fi
done
echo "Embutido em $BIN:"; cat "$BIN/VERSOES.txt"
du -sh "$BIN/llama.cpp" "$BIN/git" 2>/dev/null || true
