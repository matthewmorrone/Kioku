#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# When --files <path>... is passed, only check those paths (must be Swift files
# under Kioku/). Used by editor/PostToolUse hooks for per-file feedback.
SCOPED_FILES=()
QUIET=0
if [[ "${1:-}" == "--files" ]]; then
  shift
  for arg in "$@"; do
    case "$arg" in
      --quiet) QUIET=1 ;;
      *) SCOPED_FILES+=("$arg") ;;
    esac
  done
fi

RG_BIN=""
if command -v rg >/dev/null 2>&1; then
  RG_BIN="$(command -v rg)"
elif [[ -x "/opt/homebrew/bin/rg" ]]; then
  RG_BIN="/opt/homebrew/bin/rg"
elif [[ -x "/usr/local/bin/rg" ]]; then
  RG_BIN="/usr/local/bin/rg"
fi

EXIT_CODE=0
WARNING_COUNT=0

list_swift_files() {
  if (( ${#SCOPED_FILES[@]} > 0 )); then
    for f in "${SCOPED_FILES[@]}"; do
      # Normalize to repo-relative; skip non-Kioku Swift files silently.
      rel="${f#"$ROOT_DIR"/}"
      [[ "$rel" == Kioku/*.swift || "$rel" == Kioku/**/*.swift ]] || continue
      [[ -f "$rel" ]] && printf '%s\n' "$rel"
    done
    return
  fi

  if [[ -n "$RG_BIN" ]]; then
    "$RG_BIN" --files Kioku --glob '*.swift' | sort
    return
  fi

  find Kioku -type f -name '*.swift' | sort
}

search_swift_files() {
  local perl_pattern="$1"
  local is_multiline="${2:-false}"

  # Build the file list once — scoped mode searches only listed files; otherwise
  # search the whole Kioku tree.
  local -a targets=()
  if (( ${#SCOPED_FILES[@]} > 0 )); then
    while IFS= read -r f; do targets+=("$f"); done < <(list_swift_files)
    (( ${#targets[@]} > 0 )) || return 0
  else
    targets=(Kioku)
  fi

  if [[ -n "$RG_BIN" ]]; then
    # -H forces filename:line prefix even when only one target is given (scoped mode).
    if [[ "$is_multiline" == "true" ]]; then
      "$RG_BIN" -HnU --glob '*.swift' "$perl_pattern" "${targets[@]}" || true
    else
      "$RG_BIN" -Hn --glob '*.swift' "$perl_pattern" "${targets[@]}" || true
    fi
    return
  fi

  if (( ${#SCOPED_FILES[@]} > 0 )); then
    # Direct file list, no find.
    if [[ "$is_multiline" == "true" ]]; then
      printf '%s\0' "${targets[@]}" | xargs -0 perl -0ne '
        while (/'"$perl_pattern"'/gms) {
          $line = substr($_, 0, pos($_));
          $line_number = ($line =~ tr/\n//) + 1;
          print "$ARGV:$line_number:$&\n";
        }
      ' 2>/dev/null || true
    else
      printf '%s\0' "${targets[@]}" | xargs -0 perl -ne '
        if (/'"$perl_pattern"'/) {
          print "$ARGV:$.:$_";
        }
      ' 2>/dev/null || true
    fi
    return
  fi

  local find_args=(-type f -name '*.swift')
  if [[ "$is_multiline" == "true" ]]; then
    find Kioku "${find_args[@]}" -print0 | xargs -0 perl -0ne '
      while (/'"$perl_pattern"'/gms) {
        $line = substr($_, 0, pos($_));
        $line_number = ($line =~ tr/\n//) + 1;
        print "$ARGV:$line_number:$&\n";
      }
    ' 2>/dev/null || true
    return
  fi

  find Kioku "${find_args[@]}" -print0 | xargs -0 perl -ne '
    if (/'"$perl_pattern"'/) {
      print "$ARGV:$.:$_";
    }
  ' 2>/dev/null || true
}

report_failure() {
  echo "FAIL: $1"
  EXIT_CODE=1
}

report_warning() {
  echo "WARN: $1"
  WARNING_COUNT=1
}

report_group_matches() {
  local title="$1"
  local matches="$2"

  if [[ -n "$matches" ]]; then
    report_failure "$title"
    printf '%s\n' "$matches"
  fi
}

# Invariant 4: Swift files should warn above 800 lines and fail above 1,000 lines.
# Threshold tightened from 1200 after the May 2026 refactor brought the longest
# file under 800; the smaller margin makes drift harder to ignore.
while IFS= read -r file_path; do
  line_count=$(wc -l < "$file_path")
  if (( line_count > 1000 )); then
    report_failure "Swift file exceeds 1000 lines: ${file_path} (${line_count} lines)"
  elif (( line_count > 800 )); then
    report_warning "Swift file exceeds 800-line warning threshold: ${file_path} (${line_count} lines)"
  fi
done < <(list_swift_files)

# Invariant 1: Avoid while true loops.
while_true_matches=$(search_swift_files 'while[[:space:]]+true\b')
report_group_matches "Found forbidden while true loop(s)." "$while_true_matches"

# Invariant 2: Avoid empty catch blocks (single-line and simple multiline forms).
empty_catch_single=$(search_swift_files 'catch[[:space:]]*\{[[:space:]]*\}')
report_group_matches "Found empty catch block(s) on a single line." "$empty_catch_single"

empty_catch_multiline=$(search_swift_files 'catch[[:space:]]*\{[[:space:]\n]*\}' true)
report_group_matches "Found empty catch block(s) in multiline form." "$empty_catch_multiline"

# Invariant 6: Every function needs an intent comment immediately above it (ignoring blank/attribute lines).
while IFS= read -r file_path; do
  awk -v file_path="$file_path" '
  function is_blank(line) {
    return line ~ /^[[:space:]]*$/
  }
  function is_attribute(line) {
    return line ~ /^[[:space:]]*@/
  }
  function is_line_comment(line) {
    return line ~ /^[[:space:]]*\/\//
  }
  {
    lines[NR] = $0
  }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /(^|[^A-Za-z0-9_])func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
        j = i - 1
        while (j >= 1 && (is_blank(lines[j]) || is_attribute(lines[j]))) {
          j--
        }
        if (j < 1 || !is_line_comment(lines[j])) {
          printf("%s:%d: function is missing intent comment immediately above declaration\n", file_path, i)
          missing = 1
        }
      }
    }
    if (missing == 1) {
      exit 1
    }
  }
  ' "$file_path" || EXIT_CODE=1
done < <(list_swift_files)

# Invariant 7: Every View/UIViewRepresentable needs an ownership comment immediately above type declaration.
while IFS= read -r file_path; do
  awk -v file_path="$file_path" '
  function is_blank(line) {
    return line ~ /^[[:space:]]*$/
  }
  function is_line_comment(line) {
    return line ~ /^[[:space:]]*\/\//
  }
  {
    lines[NR] = $0
  }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /^[[:space:]]*(struct|class|actor)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*.*(^|[^A-Za-z0-9_])(View|UIViewRepresentable)($|[^A-Za-z0-9_])/) {
        j = i - 1
        while (j >= 1 && is_blank(lines[j])) {
          j--
        }
        if (j < 1 || !is_line_comment(lines[j])) {
          printf("%s:%d: View/UIViewRepresentable is missing ownership comment immediately above declaration\n", file_path, i)
          missing = 1
        }
      }
    }
    if (missing == 1) {
      exit 1
    }
  }
  ' "$file_path" || EXIT_CODE=1
done < <(list_swift_files)

# Invariant 8: every persistence store should have a matching *Tests.swift file
# under KiokuTests/. Warning-level — surfaces coverage gaps without blocking.
# Only runs in whole-tree mode; per-edit hook would re-flag on every touch.
#
# A store can opt into "covered by sibling" by adding a one-line directive at the
# top of the file:
#
#     // invariant-store-test-coverage: WordsStoreTests.swift
#
# Useful when the storage type is exercised end-to-end by tests for a higher-level
# store that owns it (e.g., SavedWordStorage covered by WordsStoreTests). The
# checker still verifies the named sibling file exists so the directive can't
# rot silently.
if (( ${#SCOPED_FILES[@]} == 0 )); then
  while IFS= read -r store_file; do
    base="$(basename "$store_file" .swift)"
    # Extensions (X+Foo.swift) inherit the primary file's contract.
    [[ "$base" == *"+"* ]] && continue
    test_name="${base}Tests.swift"
    found="$(find KiokuTests -name "$test_name" -print -quit)"
    if [[ -n "$found" ]]; then
      continue
    fi
    coverage_directive="$(grep -E '^[[:space:]]*//[[:space:]]*invariant-store-test-coverage:[[:space:]]*[A-Za-z0-9_+.]+\.swift' "$store_file" | head -1 || true)"
    if [[ -n "$coverage_directive" ]]; then
      sibling="$(printf '%s' "$coverage_directive" | sed -E 's|.*coverage:[[:space:]]*||' | tr -d '[:space:]')"
      sibling_found="$(find KiokuTests -name "$sibling" -print -quit)"
      if [[ -n "$sibling_found" ]]; then
        continue
      fi
      report_warning "Store ${store_file} declares coverage by ${sibling} but ${sibling} not found in KiokuTests/"
      continue
    fi
    report_warning "Store has no matching test file: ${store_file} (expected KiokuTests/${test_name})"
  done < <(list_swift_files | grep -E '(Store|Storage)\.swift$' || true)
fi

if (( EXIT_CODE == 0 )); then
  if (( WARNING_COUNT == 0 )); then
    # In --quiet mode (used by editor hooks), say nothing when clean — silence
    # means "no findings for the file you just touched."
    (( QUIET == 1 )) || echo "Invariant checks passed."
  else
    echo "Invariant checks passed with warnings."
  fi
else
  echo "Invariant checks failed."
fi

exit "$EXIT_CODE"
