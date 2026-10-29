#!/usr/bin/env bash
# Supabase migrations are append-only. Once a file in supabase/migrations/ is on
# main (and therefore possibly applied to production), it must never change,
# move or disappear: `supabase db push` only compares version numbers, so an
# edited migration is silently NOT re-run and production drifts from the repo.
#
# Used by CI (PRs and pushes), the pre-commit/pre-push hooks and the Deploy
# Supabase workflow. Two modes:
#
#   check-migrations.sh diff <base-ref> [<head-ref>]
#       Fails if <head-ref> (default HEAD) modifies, deletes or renames a
#       migration that already exists at <base-ref>. Pure git, no network.
#       CI passes the PR base / the push's `before` sha; the hooks pass the
#       remote-tracking main.
#
#   check-migrations.sh remote <linked|local>
#       Compares the migration history of a database with the repo:
#         * a version applied to the database with no file in the repo  -> fail
#         * a pending version older than the newest applied one          -> fail
#           (db push would refuse it without --include-all)
#         * an applied version whose file differs (ignoring whitespace) from
#           the statements the database recorded when it ran it
#           (`supabase migration fetch`)                                  -> fail
#       Then prints the pending migrations and flags destructive statements
#       (DROP TABLE/SCHEMA/COLUMN, TRUNCATE, DELETE FROM) that run when they are
#       applied: comments and `create function|procedure` bodies don't count,
#       DO blocks and other dollar-quoted text do.
#       `linked` needs `supabase link` and SUPABASE_DB_PASSWORD in the
#       environment; `local` needs the local stack (and reports any migration
#       you edited after applying it locally).
#
#   check-migrations.sh destructive <file>...
#       Prints the destructive statements those files run; exit 1 if any.
#
# When $GITHUB_OUTPUT is set, `remote` writes pending_count, pending (space
# separated versions) and destructive (true|false) to it, and a Markdown report
# to $GITHUB_STEP_SUMMARY.

set -euo pipefail

MIG_DIR="supabase/migrations"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

die() { echo "::error::$*" >&2; exit 1; }
note() { echo "$*"; }

usage() {
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
  fi
}

# normalize <file>: SQL with all whitespace and trailing semicolons removed.
normalize() {
  [ -f "$1" ] || { echo "<missing>"; return 0; }
  tr -d '[:space:]' < "$1" | sed 's/;*$//'
}

# destructive_hits <file>: "line:text" for each DROP TABLE/SCHEMA/COLUMN, TRUNCATE or DELETE FROM
# that runs when the migration is applied. Comments and the bodies of `create function` /
# `create procedure` are blanked first (sql_executed_text.py): a redefined function that
# deletes when it is *called* destroys nothing at deploy time. DO blocks still count.
destructive_hits() {
  python3 "$REPO_ROOT/scripts/ci/sql_executed_text.py" "$1" \
    | grep -inE '\b(drop[[:space:]]+(table|schema|column)|truncate|delete[[:space:]]+from)\b' \
    | sed -E 's/[[:space:]]+$//' || true
}

# mig_file <version>: path of the migration file for a version, or nothing.
mig_file() {
  local f
  for f in "$MIG_DIR/$1"_*.sql; do
    [ -e "$f" ] && { echo "$f"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------------------
mode_diff() {
  local base="${1:-}" head="${2:-HEAD}"
  [ -n "$base" ] || usage

  if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    note "check-migrations: base '$base' is not available locally; skipping the append-only diff."
    return 0
  fi

  local bad=() status path old new
  # --no-renames: a rename shows up as D (old) + A (new), and the D is the violation.
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    case "$status" in
      M*|D*|T*)
        if git cat-file -e "${base}:${path}" 2>/dev/null; then
          bad+=("$status $path")
        fi
        ;;
    esac
  done < <(git diff --no-renames --name-status "$base" "$head" -- "$MIG_DIR" | awk -F'\t' '{print $1"\t"$2}')

  # A new file must sort after every migration already on base, or `db push`
  # treats it as out of order.
  local newest_base
  newest_base="$(git ls-tree --name-only "$base" -- "$MIG_DIR/" 2>/dev/null \
    | sed -n 's#.*/\([0-9]\{14\}\)_.*\.sql$#\1#p' | sort | tail -1)"
  while IFS= read -r new; do
    [ -n "$new" ] || continue
    old="$(basename "$new" | cut -c1-14)"
    if [ -n "$newest_base" ] && [[ "$old" < "$newest_base" || "$old" == "$newest_base" ]]; then
      bad+=("A(out of order: $old <= $newest_base) $new")
    fi
  done < <(git diff --no-renames --name-only --diff-filter=A "$base" "$head" -- "$MIG_DIR" | grep -E '\.sql$' || true)

  if [ "${#bad[@]}" -gt 0 ]; then
    echo "Migrations are append-only. These changes rewrite history that may already be applied:" >&2
    printf '  %s\n' "${bad[@]}" >&2
    echo "Add a NEW migration (supabase migration new <name>) instead of editing an existing one," >&2
    echo "and give it a timestamp later than every migration on main." >&2
    die "append-only migration check failed (${#bad[@]} file(s))"
  fi
  note "check-migrations: append-only OK against ${base:0:12}"
}

# ---------------------------------------------------------------------------
mode_remote() {
  local target="${1:-}"
  case "$target" in
    linked) set -- --linked ;;
    local) set -- --local ;;
    *) usage ;;
  esac
  local flag="$1"
  command -v jq >/dev/null || die "jq is required"

  local args=(migration list "$flag" --output-format json)
  if [ "$flag" = "--linked" ] && [ -n "${SUPABASE_DB_PASSWORD:-}" ]; then
    args+=(--password "$SUPABASE_DB_PASSWORD")
  fi

  local raw json
  raw="$(supabase "${args[@]}" 2>/dev/null)" || die "supabase migration list $flag failed"
  # Keep only the JSON document (the CLI may print a banner line first).
  json="$(printf '%s\n' "$raw" | sed -n '/^{/,$p')"
  [ -n "$json" ] || die "could not parse 'supabase migration list' output"

  # Newline-separated version lists (bash 3.2 on macOS has no mapfile, and an
  # empty "${arr[@]}" trips `set -u` there). Versions never contain spaces.
  local applied pending remote_only newest_remote
  applied="$(jq -r '.migrations[] | select((.local // "") != "" and (.remote // "") != "") | .local' <<<"$json")"
  pending="$(jq -r '.migrations[] | select((.local // "") != "" and (.remote // "") == "") | .local' <<<"$json")"
  remote_only="$(jq -r '.migrations[] | select((.local // "") == "" and (.remote // "") != "") | .remote' <<<"$json")"
  newest_remote="$(jq -r '[.migrations[] | select((.remote // "") != "") | .remote] | max // ""' <<<"$json")"

  local errors=0 v f

  if [ -n "$remote_only" ]; then
    echo "Applied to the database but missing from $MIG_DIR (deleted or renamed?):" >&2
    # shellcheck disable=SC2086 # word-split on purpose: one version per line
    printf '  %s\n' $remote_only >&2
    errors=$((errors + 1))
  fi

  for v in $pending; do
    if [ -n "$newest_remote" ] && [[ "$v" < "$newest_remote" ]]; then
      echo "Pending migration $v is older than the newest applied one ($newest_remote)." >&2
      errors=$((errors + 1))
    fi
  done

  # Immutability: the database keeps the statements of every migration it ran
  # (supabase_migrations.schema_migrations). Fetch them into a scratch project
  # and compare with the repo files, ignoring whitespace (the CLI re-joins the
  # statements it parsed). Any other difference means a migration was edited
  # after it ran, and production no longer matches what the repo says.
  local scratch changed=""
  scratch="$(mktemp -d)"
  mkdir -p "$scratch/supabase"
  cp supabase/config.toml "$scratch/supabase/"
  # config.toml references files (auth email templates); the CLI refuses to load it without them.
  [ -d supabase/templates ] && cp -R supabase/templates "$scratch/supabase/"
  [ -d supabase/.temp ] && cp -R supabase/.temp "$scratch/supabase/"
  # config.toml's [remotes.production] reads env() from supabase/.env (CI sets the env instead).
  [ -f supabase/.env ] && cp supabase/.env "$scratch/supabase/"
  if ! (cd "$scratch" && supabase migration fetch "$flag" --yes >/dev/null 2>&1); then
    rm -rf "$scratch"
    die "supabase migration fetch $flag failed"
  fi
  for v in $applied; do
    f="$(mig_file "$v")"
    [ -n "$f" ] || continue
    if [ "$(normalize "$f")" != "$(normalize "$scratch/$f")" ]; then
      changed="$changed  $f"$'\n'
    fi
  done
  rm -rf "$scratch"
  if [ -n "$changed" ]; then
    echo "Applied migrations whose repo file differs from what the database ran (append-only):" >&2
    printf '%s' "$changed" >&2
    echo "Restore the original file content and put the change in a NEW migration." >&2
    errors=$((errors + 1))
  fi

  # Destructive statements in what is about to run (see destructive_hits).
  local destructive=false hits=() hit line
  for v in $pending; do
    f="$(mig_file "$v")"
    [ -n "$f" ] || continue
    hit="$(destructive_hits "$f")"
    if [ -n "$hit" ]; then
      destructive=true
      while IFS= read -r line; do hits+=("$(basename "$f"):$line"); done <<<"$hit"
    fi
  done

  local count n_applied
  count="$(grep -c . <<<"$pending" || true)"
  n_applied="$(grep -c . <<<"$applied" || true)"
  note "Applied: $n_applied  Pending: $count  Newest applied: ${newest_remote:-none}"
  if [ "$count" -gt 0 ]; then
    note "Pending migrations:"
    for v in $pending; do note "  $(basename "$(mig_file "$v")")"; done
  fi
  if [ "$destructive" = true ]; then
    note "::warning::Pending migrations contain destructive statements:"
    printf '  %s\n' "${hits[@]}"
  fi

  summary "### Supabase migrations ($target)" "" \
    "| | |" "|---|---|" \
    "| Newest applied | \`${newest_remote:-none}\` |" \
    "| Pending | $count |" \
    "| Destructive statements in pending | $destructive |" ""
  if [ "$count" -gt 0 ]; then
    summary "Pending:" ""
    for v in $pending; do summary "- \`$(basename "$(mig_file "$v")")\`"; done
    summary ""
  fi
  if [ "$destructive" = true ]; then
    summary "Destructive lines:" "" '```'
    summary "${hits[@]}"
    summary '```' ""
  fi

  output "pending_count=$count" "pending=$(tr '\n' ' ' <<<"$pending" | sed 's/ *$//')" "destructive=$destructive"

  [ "$errors" -eq 0 ] || die "migration history check failed ($errors problem(s)); nothing applied"
  note "check-migrations: history OK"
}

# destructive <file>...: print the destructive statements each file runs; exit 1 if any.
mode_destructive() {
  [ "$#" -gt 0 ] || usage
  local f hit found=0
  for f in "$@"; do
    [ -f "$f" ] || die "no such file: $f"
    hit="$(destructive_hits "$f")"
    if [ -n "$hit" ]; then
      found=1
      while IFS= read -r line; do echo "$f:$line"; done <<<"$hit"
    fi
  done
  return "$found"
}

case "${1:-}" in
  diff) shift; mode_diff "$@" ;;
  remote) shift; mode_remote "$@" ;;
  destructive) shift; mode_destructive "$@" ;;
  *) usage ;;
esac
