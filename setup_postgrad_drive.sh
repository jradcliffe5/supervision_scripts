#!/usr/bin/env bash

# Builds a supervision-ready workspace for a single postgraduate student.
# Run from (or point to) the supervisor's shared drive location. The script is
# idempotent: re-running it keeps existing files intact and fills in anything
# missing.

set -euo pipefail

if [[ -n "${ZSH_VERSION:-}" ]]; then
  emulate -L sh
  setopt errexit
  setopt nounset
  setopt pipefail
fi

SHARED_DIR=""
SUPERVISOR_DIR=""
PRIVATE_TEMPLATE_DIR=""
NEEDS_TEMPLATE_REFRESH=false
PROGRAM_SLUG=""
STUDENT_SLUG=""
PANDOC_CHECKED=false
PANDOC_AVAILABLE=false
PANDOC_WARNED=false
CLEANUP_MODE="false"
LAST_BACKUP_DIR=""

ROOT_DIR="$(pwd)"
STUDENT_SPEC=""
CUSTOM_FOLDER_NAME=""

STUDENT_PROGRAM=""
STUDENT_NAME=""
STUDENT_YEAR=""
STUDENT_SUPERVISOR=""
STUDENT_CO_SUPERVISOR=""
STUDENT_NOTES=""

usage() {
  cat <<'EOF'
Usage: setup_postgrad_drive.sh --student "PROGRAM|Full Name|Start Year|Supervisor|Co-supervisor|Notes" [options]

Options:
  --root DIR          Base directory where the student workspace will be created (defaults to cwd).
  --student SPEC      Required. Pipe-separated student info:
                      level|Full Name|Start Year|Supervisor|Co-supervisor|Notes
                      Missing trailing fields are allowed.
  --folder-name NAME  Override the generated folder name (relative to --root).
  --cleanup           Remove the generated workspace for the supplied student instead of creating it.
                      Requires --student (and optional --folder-name to target a custom name).
  -h, --help          Show this help message and exit.

Example:
  ./setup_postgrad_drive.sh --root "/Shared/Supervision" \
    --student "PhD|Jane Doe|2024|Dr Jack Radcliffe|Dr Co Super|MeerKAT VLBI project"
EOF
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

abort() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

capitalize_token() {
  local token="$1"
  if [[ -z "$token" ]]; then
    printf ''
    return
  fi
  local lower
  lower="$(lowercase "$token")"
  local first="${lower:0:1}"
  local rest="${lower:1}"
  if [[ -n "$first" ]]; then
    first="$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')"
  fi
  printf '%s%s' "$first" "$rest"
}

canonical_program() {
  local raw
  raw="$(lowercase "$1")"
  raw="${raw//./}"
  raw="${raw// /}"
  case "$raw" in
    master|masters|msc|mres|ms|ma|m)
      printf 'Masters'
      ;;
    phd|phdprogramme|phdprogram|phdstudent|phdtrack|phdprog|phdstudents|phdstudies|phdstudy|phdprogrammes|phdprograms|ph)
      printf 'PhD'
      ;;
    doctoral|doctorate|doctorial|dphil|dph|dphilstudies|dphilstudent|phdt)
      printf 'PhD'
      ;;
    *)
      return 1
      ;;
  esac
}

program_slug_from_name() {
  local program="$1"
  local slug
  slug="$(lowercase "$program")"
  slug="${slug// /_}"
  slug="${slug//[^a-z0-9_]/}"
  printf '%s' "$slug"
}

ensure_pandoc() {
  if [[ "$PANDOC_CHECKED" == "true" ]]; then
    return
  fi
  if command -v pandoc >/dev/null 2>&1; then
    PANDOC_AVAILABLE="true"
  else
    PANDOC_AVAILABLE="false"
  fi
  PANDOC_CHECKED="true"
}

convert_markdown_to_pdf() {
  local md_file="$1"
  local pdf_file="${md_file%.md}.pdf"

  if [[ "${md_file##*.}" != "md" ]]; then
    return
  fi

  ensure_pandoc

  if [[ "$PANDOC_AVAILABLE" != "true" ]]; then
    if [[ "$PANDOC_WARNED" != "true" ]]; then
      warn "pandoc not found; skipping PDF exports"
      PANDOC_WARNED="true"
    fi
    return
  fi

  if [[ -f "$pdf_file" && ! "$md_file" -nt "$pdf_file" ]]; then
    return
  fi

  if ! pandoc "$md_file" -o "$pdf_file" \
      -V geometry:margin=15mm \
      -V colorlinks=true \
      -V linkcolor=RoyalBlue \
      -V urlcolor=RoyalBlue \
      -V citecolor=ForestGreen >/dev/null 2>&1; then
    warn "Failed to convert '${md_file}' to PDF"
  fi
}

slugify_name() {
  local full="$1"
  full="$(trim "$full")"
  full="$(printf '%s' "$full" | tr '\t' ' ')"
  full="$(printf '%s' "$full" | tr -s ' ' ' ')"
  full="${full//$'\r'/}"
  if [[ -z "$full" ]]; then
    printf 'unnamed_student'
    return
  fi

  local last="${full##* }"
  local rest="${full% $last}"
  if [[ "$rest" == "$full" ]]; then
    local sanitized="${full// /_}"
    sanitized="${sanitized//[^[:alnum:]_]/}"
    printf '%s' "$sanitized"
    return
  fi

  rest="${rest// /_}"
  rest="${rest//[^[:alnum:]_]/}"
  last="${last// /_}"
  last="${last//[^[:alnum:]_]/}"

  if [[ -z "$rest" ]]; then
    printf '%s' "$(lowercase "$last")"
  else
    printf '%s_%s' "$(lowercase "$last")" "$(lowercase "$rest")"
  fi
}

last_name_folder_component() {
  local full="$1"
  full="$(trim "$full")"
  full="$(printf '%s' "$full" | tr '\t' ' ')"
  full="$(printf '%s' "$full" | tr -s ' ' ' ')"
  full="${full//$'\r'/}"

  if [[ -z "$full" ]]; then
    printf ''
    return
  fi

  local last="$full"
  if [[ "$full" == *" "* ]]; then
    last="${full##* }"
  fi
  last="${last//[^[:alnum:]]/}"

  if [[ -z "$last" ]]; then
    printf ''
    return
  fi

  printf '%s' "$(capitalize_token "$last")"
}

current_year() {
  date '+%Y'
}

program_folder_code() {
  local program="$1"
  case "$program" in
    Masters)
      printf 'MSc'
      ;;
    PhD)
      printf 'PhD'
      ;;
    *)
      local cleaned
      cleaned="$(trim "$program")"
      cleaned="${cleaned// /}"
      cleaned="${cleaned//[^[:alnum:]]/}"
      if [[ -z "$cleaned" ]]; then
        cleaned="Programme"
      fi
      printf '%s' "$cleaned"
      ;;
  esac
}

derive_student_folder_name() {
  local program="$1"
  local full_name="$2"
  local start_year="$3"

  local slug
  slug="$(slugify_name "$full_name")"
  local year="${start_year//[^0-9]/}"
  if [[ -z "$year" ]]; then
    year="$(current_year)"
  fi

  local program_code
  program_code="$(program_folder_code "$program")"

  local last_name
  last_name="$(last_name_folder_component "$full_name")"

  if [[ -z "$last_name" ]]; then
    local fallback="${slug%%_*}"
    fallback="${fallback//[^[:alnum:]]/}"
    last_name="$(capitalize_token "$fallback")"
  fi

  if [[ -z "$last_name" ]]; then
    last_name="Student"
  fi

  printf '%s_%s_%s' "$year" "$program_code" "$last_name"
}

derive_shared_dir_name() {
  local program="$1"
  local student_slug="$2"

  local program_slug
  program_slug="$(program_slug_from_name "$program")"

  printf 'shared_%s_%s' "$program_slug" "$student_slug"
}

ensure_directory() {
  local path="$1"
  mkdir -p "$path"
}

move_legacy_item() {
  local source="$1"
  local target="$2"

  if [[ ! -e "$source" ]]; then
    return 1
  fi

  ensure_directory "$(dirname "$target")"

  python3 - <<'PY' "$source" "$target"
import os
import shutil
import sys

source, target = sys.argv[1], sys.argv[2]

if not os.path.exists(source):
    sys.exit(1)

if os.path.abspath(source) == os.path.abspath(target):
    sys.exit(1)

target_parent = os.path.dirname(target)
os.makedirs(target_parent, exist_ok=True)

try:
    os.replace(source, target)
    sys.exit(0)
except OSError:
    pass

tmp_target = target + ".codex_tmp"
try:
    os.replace(source, tmp_target)
    os.replace(tmp_target, target)
    sys.exit(0)
except OSError:
    if os.path.isdir(source):
        os.makedirs(target, exist_ok=True)
        for entry in os.listdir(source):
            shutil.move(os.path.join(source, entry), target)
        try:
            shutil.rmtree(source)
        except OSError:
            pass
        try:
            if os.path.isdir(tmp_target):
                shutil.rmtree(tmp_target)
        except OSError:
            pass
        sys.exit(0)
    else:
        try:
            shutil.move(source, target)
            sys.exit(0)
        except Exception:
            try:
                if os.path.isdir(tmp_target):
                    shutil.rmtree(tmp_target)
            except OSError:
                pass
            sys.exit(2)
PY
  local status=$?
  if [[ $status -eq 0 ]]; then
    return 0
  elif [[ $status -eq 1 ]]; then
    return 1
  else
    warn "Legacy item '$source' could not be migrated to '$target'"
    return 1
  fi
}

move_directory_contents() {
  local source="$1"
  local target="$2"

  if [[ ! -d "$source" ]]; then
    return 1
  fi

  ensure_directory "$target"

  local moved_any=false

  shopt -s dotglob nullglob
  for item in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [[ ! -e "$item" ]] && continue
    mv "$item" "$target/"
    moved_any=true
  done
  shopt -u dotglob nullglob

  if [[ "$moved_any" == true ]]; then
    rmdir "$source" 2>/dev/null || true
    return 0
  fi

  return 1
}

create_file_if_missing() {
  local path="$1"
  local content="$2"

  if [[ -f "$path" ]]; then
    return
  fi

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
}

create_template_meeting_notes() {
  local file="$1"

  if [[ -f "$file" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<'EOF'
---
title: "Supervision meeting notes template"
subject: "Supervision meeting capture"
---

- **Student:** {{STUDENT_NAME}}
- **Supervisors:** {{SUPERVISORS}}
- **Date:** {{DATE}}
- **Next meeting:** {{NEXT_MEETING}}

## Agenda
- Topic 1
- Topic 2
- Risks / blockers

## Discussion notes
- 

## Action items
| Action | Owner | Due | Status |
|--------|-------|-----|--------|
| Example task | Student | YYYY-MM-DD | Open |

## Follow-up
- 
EOF
  convert_markdown_to_pdf "$file"
}

create_template_progress_report() {
  local file="$1"
  local program="$2"

  if [[ -f "$file" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<EOF
---
title: "${program} progress review template"
subject: "${program} progress reflection"
---

| Item | Details |
|------|---------|
| Student | {{STUDENT_NAME}} |
| Programme | ${program} |
| Review period | {{REVIEW_PERIOD}} |
| Supervisory team | {{SUPERVISORS}} |

## Highlights
- 

## Challenges / risks
- 

## Publications & outputs
- 

## Planned work (next period)
- 

## Support needed
- 
EOF
  convert_markdown_to_pdf "$file"
}

create_template_onboarding() {
  local file="$1"
  local program="$2"

  if [[ -f "$file" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<EOF
---
title: "${program} student onboarding checklist"
subject: "Early-stage onboarding tasks"
---

- [ ] Store admission letter in ../../01_admin/registration
- [ ] Capture funding agreements and bursary letters in ../../01_admin/funding
- [ ] Schedule first supervision meeting and set cadence
- [ ] Share policies (ethics, data management, plagiarism)
- [ ] Provide access to calendars, Slack/Teams, and key repositories
- [ ] Register for required coursework or training
- [ ] Agree initial research goals and draft first-semester plan
EOF
  convert_markdown_to_pdf "$file"
}

shared_common_subdirs() {
  cat <<'EOF'
00_inbox
01_research
01_research/literature
01_research/data
01_research/analysis
01_research/drafts
02_meetings
03_professional_development
04_teaching_and_outreach
05_presentations
EOF
}

supervisor_common_subdirs() {
  cat <<'EOF'
01_admin
01_admin/registration
01_admin/funding
01_admin/progress_reports
EOF
}

masters_shared_extra_subdirs() {
  cat <<'EOF'
01_research/thesis
03_professional_development/workshops
EOF
}

phd_shared_extra_subdirs() {
  cat <<'EOF'
01_research/thesis
01_research/publications
03_professional_development/conference_travel
EOF
}

masters_supervisor_extra_subdirs() {
  cat <<'EOF'
01_admin/coursework
EOF
}

phd_supervisor_extra_subdirs() {
  cat <<'EOF'
01_admin/candidacy
01_admin/examiners
EOF
}

create_student_readme() {
  local file="$1"
  local full_name="$2"
  local program="$3"
  local program_lower
  program_lower="$(lowercase "$program")"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<EOF
---
title: "${full_name} — ${program_lower} supervision workspace"
---

## Overview
This workspace keeps supervision materials, student deliverables, and key
correspondence consolidated for the ${program} journey.

## Structure
- \`${SUPERVISOR_DIR}/\` — supervisor-only admin records (registration,
  funding, progress reports, candidacy paperwork).
- \`${SHARED_DIR}/\` — share this subfolder with the student and supervisory
  team; it contains research artefacts and meeting records.
- \`${SUPERVISOR_DIR}/02_templates/\` — ready-to-copy meeting notes, progress
  reviews, onboarding checklists.
- \`supervision_quickstart.md\` — quick reference for running the supervision
  process.

## Shared subfolder highlights
- \`${SHARED_DIR}/00_inbox\` — quick drop zone before filing properly.
- \`${SHARED_DIR}/01_research\` — data products, analysis notebooks, thesis drafts.
- \`${SHARED_DIR}/02_meetings\` — agendas, notes, and action trackers.
- \`${SHARED_DIR}/03_professional_development\` — workshops, training plans, certificates.
- \`${SHARED_DIR}/04_teaching_and_outreach\` — tutoring, outreach, and demo materials.
- \`${SHARED_DIR}/05_presentations\` — talks, posters, and slides.

## Sharing guidance
Keep sensitive correspondence inside \`${SUPERVISOR_DIR}/01_admin\`.
Grant the student access to \`${SHARED_DIR}\` once the workspace is ready.
EOF
  convert_markdown_to_pdf "$file"
}

create_shared_readme() {
  local file="$1"
  local full_name="$2"
  local program="$3"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<EOF
---
title: "${full_name} shared workspace guide"
subject: "Shared supervision materials (${program})"
---

## Purpose
This folder is the collaboration space shared between the supervisory team and
the student. Anything placed here should be suitable for everyone to access.

## Subfolders
- \`00_inbox\` — quick uploads before filing.
- \`01_research\` — literature, data, analysis notebooks, thesis drafts.
- \`02_meetings\` — agendas, notes, and action items.
- \`03_professional_development\` — workshops, certificates, development plans.
- \`04_teaching_and_outreach\` — tutoring material, outreach resources.
- \`05_presentations\` — slides, posters, talk scripts.

## Exporting to pdf
When needed, convert any markdown file in this folder to PDF with Pandoc:

    pandoc filename.md -o filename.pdf \
      -V colorlinks=true \
      -V linkcolor=RoyalBlue \
      -V urlcolor=RoyalBlue \
      -V citecolor=ForestGreen

Ensure Pandoc (or an equivalent Markdown-to-PDF tool) is installed locally.
EOF
  convert_markdown_to_pdf "$file"
}

create_supervisor_private_readme() {
  local file="$1"
  local program="$2"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<EOF
---
title: "Private workspace overview"
subject: "Confidential ${program} administration"
---

## Purpose
Keep confidential administrative records in this workspace root (registration,
funding, exam correspondence). Do not share this folder with the student.

## Suggested contents
- \`01_admin/registration\` — admission letters, proof of registration.
- \`01_admin/funding\` — bursary letters, funding agreements, invoices.
- \`01_admin/progress_reports\` — progress reviews, performance notes.
- \`02_templates/\` — master copies of meeting notes, progress reviews, onboarding checklists.
- Programme-specific extras (coursework, candidacy, examiners) as required.

## Pdf conversion
The markdown files in this folder include export metadata; run

    pandoc file.md -o file.pdf \
      -V colorlinks=true \
      -V linkcolor=RoyalBlue \
      -V urlcolor=RoyalBlue \
      -V citecolor=ForestGreen

to produce a PDF copy when needed.
EOF
  convert_markdown_to_pdf "$file"
}

create_student_profile() {
  local file="$1"
  local full_name="$2"
  local program="$3"
  local start_year="$4"
  local supervisor="$5"
  local co_supervisor="$6"
  local notes="$7"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  local year="${start_year:-$(current_year)}"
  local sup="${supervisor:-Lead supervisor}"
  local co="${co_supervisor:-TBD}"
  local info_notes="${notes:-}"

  cat >"$file" <<EOF
---
title: "Student profile — ${full_name}"
subject: "${program} supervision record"
---

- **Name:** ${full_name}
- **Programme:** ${program}
- **Start year:** ${year}
- **Lead supervisor:** ${sup}
- **Co-supervisors / collaborators:** ${co}
- **Notes:** ${info_notes}

## Milestone tracker

| Milestone | Target Date | Status | Notes |
|-----------|-------------|--------|-------|
| Proposal approval | YYYY-MM-DD | Not started |  |
| Ethics clearance | YYYY-MM-DD | Not started |  |
| Draft submission | YYYY-MM-DD | Not started |  |
| Final submission | YYYY-MM-DD | Not started |  |

## Useful links

- Shared workspace: ../../${SHARED_DIR}
- Templates: ../02_templates
EOF
  convert_markdown_to_pdf "$file"
}

create_student_meeting_log() {
  local file="$1"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<'EOF'
---
title: "Supervision meeting log"
subject: "Record of meetings"
---

Use this log to capture each supervision meeting in its own section. Duplicate
the template block below and update the details for each meeting.

---

## Standing meeting details

- **Cadence:** Weekly on Tuesdays at 14:00 SAST
- **Primary connection:** Teams — recurring calendar invite
- **Supervisory team:** Lead Supervisor, Co-supervisor(s)
- **Student:** Full name
- **Backup channel:** Zoom link or phone bridge if Teams is unavailable

---

## Meeting YYYY-MM-DD

- **Date:** YYYY-MM-DD
- **Time / connection:** 14:00 SAST — Teams (link in calendar)
- **Next meeting:** TBD
- **Attendees:** Supervisor, Student
- **Apologies:** Co-supervisor

### Agenda
- Item 1
- Item 2

### Discussion notes
- Quick recap: Key outcomes or rolling context.
- Topic name: Summary of discussion and decisions.

### Action items
| Action | Owner | Due | Status |
|--------|-------|-----|--------|
| Describe the task clearly | Owner |  | Open |

### Follow-up
- Note any reminders or checks before the next meeting.
EOF
  convert_markdown_to_pdf "$file"
}

create_student_research_log() {
  local file="$1"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  cat >"$file" <<'EOF'
---
title: "Research activity log"
subject: "Tracking daily research activity"
---

| Date | Activity | Location / File | Notes |
|------|----------|-----------------|-------|
| YYYY-MM-DD | Literature review | Zotero collection |  |
EOF
  convert_markdown_to_pdf "$file"
}

create_supervisor_quickstart() {
  local file="$1"
  local full_name="$2"
  local program="$3"
  local supervisor="$4"
  local co_supervisor="$5"

  if [[ -f "$file" && "$NEEDS_TEMPLATE_REFRESH" != "true" ]]; then
    convert_markdown_to_pdf "$file"
    return
  fi

  local sup="${supervisor:-Lead supervisor}"
  local co="${co_supervisor:-None listed}"

  cat >"$file" <<EOF
---
title: "Supervision quickstart — ${full_name}"
author: "${sup}"
subject: "${program} supervision overview"
---

- **Programme:** ${program}
- **Lead supervisor:** ${sup}
- **Co-supervisors / collaborators:** ${co}

## Weekly routine
- Capture supervision meeting notes in \`${SHARED_DIR}/02_meetings/supervision_meetings.md\`.
- File official correspondence in \`${SUPERVISOR_DIR}/01_admin\`.
- Log research progress in \`${SHARED_DIR}/01_research/research_log.md\`.
- Reuse templates from \`${SUPERVISOR_DIR}/02_templates\` rather than editing originals.

## Checklist before first meeting
1. Personalise \`${SUPERVISOR_DIR}/01_admin/00_student_profile.md\`.
2. Share the onboarding checklist in \`${SUPERVISOR_DIR}/02_templates/onboarding-checklist.md\`.
3. Agree expectations for meeting cadence and response times.
4. Review data management/storage expectations and any institutional policies.

## Notes
- Archive dated material inside year-labelled subfolders (e.g. \`${SUPERVISOR_DIR}/01_admin/progress_reports/2024\`).
- Keep the shared folder clean by filing documents from \`${SHARED_DIR}/00_inbox\` regularly.
EOF
  convert_markdown_to_pdf "$file"
}

cleanup_student_structure() {
  local student_root="$1"

  LAST_BACKUP_DIR=""

  if [[ ! -d "$student_root" ]]; then
    warn "No workspace found at ${student_root}; skipping cleanup"
    return 1
  fi

  local shared_path="$student_root/$SHARED_DIR"
  local supervisor_path="$student_root/$SUPERVISOR_DIR"
  local template_path="$student_root/$PRIVATE_TEMPLATE_DIR"

  rm -rf "$shared_path"
  rm -rf "$template_path"
  rm -rf "$supervisor_path"
  rm -rf "$student_root/02_templates"
  rm -rf "$student_root/01_admin"
  rm -f "$student_root/README.md" "$student_root/README.pdf"
  rm -f "$student_root/supervision_quickstart.md" "$student_root/supervision_quickstart.pdf"

  local timestamp
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  local backup_dir="${student_root}/retained_after_cleanup_${timestamp}"
  local moved_any=false

  shopt -s dotglob nullglob
  for item in "$student_root"/* "$student_root"/.[!.]* "$student_root"/..?*; do
    [[ ! -e "$item" ]] && continue
    local name="${item##*/}"
    if [[ "$name" == "." || "$name" == ".." ]]; then
      continue
    fi
    if [[ "$name" == "${backup_dir##*/}" ]]; then
      continue
    fi
    if [[ "$name" == "$SHARED_DIR" || "$name" == "$SUPERVISOR_DIR" ]]; then
      continue
    fi
    if [[ "$name" == "02_templates" || "$name" == "01_admin" || "$name" == "supervisor_private" ]]; then
      continue
    fi
    if [[ "$name" == "README.md" || "$name" == "README.pdf" || "$name" == "supervision_quickstart.md" || "$name" == "supervision_quickstart.pdf" ]]; then
      continue
    fi
    if [[ "$moved_any" == false ]]; then
      ensure_directory "$backup_dir"
    fi
    mv "$item" "$backup_dir/"
    moved_any=true
  done
  shopt -u dotglob nullglob

  if [[ "$moved_any" == false ]]; then
    rmdir "$backup_dir" 2>/dev/null || true
  else
    LAST_BACKUP_DIR="$backup_dir"
  fi

  if rmdir "$student_root" 2>/dev/null; then
    log "Removed empty workspace directory: $student_root"
  fi

  return 0
}

create_student_structure() {
  local student_root="$1"
  local program="$2"
  local full_name="$3"
  local start_year="$4"
  local supervisor="$5"
  local co_supervisor="$6"
  local notes="$7"

  local shared_root="$student_root/$SHARED_DIR"
  local supervisor_root="$student_root/$SUPERVISOR_DIR"
  local template_root="$student_root/$PRIVATE_TEMPLATE_DIR"
  local migrated=false

  NEEDS_TEMPLATE_REFRESH="false"

  ensure_directory "$student_root"

  ensure_directory "$shared_root"
  ensure_directory "$supervisor_root"
  ensure_directory "$template_root"

  if move_legacy_item "$student_root/Shared_with_Student" "$shared_root"; then migrated=true; fi
  if move_legacy_item "$student_root/shared_with_student" "$shared_root"; then migrated=true; fi
  if move_legacy_item "$student_root/Supervisor_Private" "$supervisor_root"; then migrated=true; fi
  if move_legacy_item "$student_root/supervisor_private" "$supervisor_root"; then migrated=true; fi

  if move_legacy_item "$student_root/00_Inbox" "$shared_root/00_Inbox"; then migrated=true; fi
  if move_legacy_item "$student_root/00_inbox" "$shared_root/00_inbox"; then migrated=true; fi
  if move_legacy_item "$student_root/02_Research" "$shared_root/02_Research"; then migrated=true; fi
  if move_legacy_item "$student_root/02_research" "$shared_root/02_Research"; then migrated=true; fi
  if move_legacy_item "$student_root/03_Meetings" "$shared_root/03_Meetings"; then migrated=true; fi
  if move_legacy_item "$student_root/03_meetings" "$shared_root/03_Meetings"; then migrated=true; fi
  if move_legacy_item "$student_root/04_Professional_Development" "$shared_root/04_Professional_Development"; then migrated=true; fi
  if move_legacy_item "$student_root/04_professional_development" "$shared_root/04_Professional_Development"; then migrated=true; fi
  if move_legacy_item "$student_root/05_Teaching_and_Outreach" "$shared_root/05_Teaching_and_Outreach"; then migrated=true; fi
  if move_legacy_item "$student_root/05_teaching_and_outreach" "$shared_root/05_Teaching_and_Outreach"; then migrated=true; fi
  if move_legacy_item "$student_root/06_Presentations" "$shared_root/06_Presentations"; then migrated=true; fi
  if move_legacy_item "$student_root/06_presentations" "$shared_root/06_Presentations"; then migrated=true; fi
  if move_legacy_item "$student_root/Templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$student_root/templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$student_root/06_Templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$student_root/06_templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$shared_root/Templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$shared_root/templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$shared_root/06_templates" "$template_root"; then migrated=true; fi
  if move_legacy_item "$student_root/01_Admin" "$supervisor_root/01_Admin"; then migrated=true; fi
  if move_legacy_item "$student_root/01_admin" "$supervisor_root/01_Admin"; then migrated=true; fi

  if [[ -f "$student_root/private_workspace_overview.md" ]]; then
    ensure_directory "$supervisor_root"
    mv "$student_root/private_workspace_overview.md" "$supervisor_root/" 2>/dev/null || true
    migrated=true
  fi
  if [[ -f "$student_root/private_workspace_overview.pdf" ]]; then
    ensure_directory "$supervisor_root"
    mv "$student_root/private_workspace_overview.pdf" "$supervisor_root/" 2>/dev/null || true
    migrated=true
  fi

  if move_legacy_item "$shared_root/00_Inbox" "$shared_root/00_inbox"; then migrated=true; fi
  if move_legacy_item "$shared_root/02_Research" "$shared_root/01_research"; then migrated=true; fi
  if move_legacy_item "$shared_root/02_research" "$shared_root/01_research"; then migrated=true; fi
  if move_legacy_item "$shared_root/03_Meetings" "$shared_root/02_meetings"; then migrated=true; fi
  if move_legacy_item "$shared_root/03_meetings" "$shared_root/02_meetings"; then migrated=true; fi
  if move_legacy_item "$shared_root/04_Professional_Development" "$shared_root/03_professional_development"; then migrated=true; fi
  if move_legacy_item "$shared_root/04_professional_development" "$shared_root/03_professional_development"; then migrated=true; fi
  if move_legacy_item "$shared_root/05_Teaching_and_Outreach" "$shared_root/04_teaching_and_outreach"; then migrated=true; fi
  if move_legacy_item "$shared_root/05_teaching_and_outreach" "$shared_root/04_teaching_and_outreach"; then migrated=true; fi
  if move_legacy_item "$shared_root/06_Presentations" "$shared_root/05_presentations"; then migrated=true; fi
  if move_legacy_item "$shared_root/06_presentations" "$shared_root/05_presentations"; then migrated=true; fi

  if move_legacy_item "$shared_root/01_research/Literature" "$shared_root/01_research/literature"; then migrated=true; fi
  if move_legacy_item "$shared_root/01_research/Data" "$shared_root/01_research/data"; then migrated=true; fi
  if move_legacy_item "$shared_root/01_research/Analysis" "$shared_root/01_research/analysis"; then migrated=true; fi
  if move_legacy_item "$shared_root/01_research/Drafts" "$shared_root/01_research/drafts"; then migrated=true; fi
  if move_legacy_item "$shared_root/01_research/Thesis" "$shared_root/01_research/thesis"; then migrated=true; fi
  if move_legacy_item "$shared_root/01_research/Publications" "$shared_root/01_research/publications"; then migrated=true; fi
  if move_legacy_item "$shared_root/02_meetings/Supervision" "$shared_root/02_meetings/supervision"; then migrated=true; fi
  if move_legacy_item "$shared_root/03_professional_development/Workshops" "$shared_root/03_professional_development/workshops"; then migrated=true; fi
  if move_legacy_item "$shared_root/03_professional_development/Conference_Travel" "$shared_root/03_professional_development/conference_travel"; then migrated=true; fi

  if move_legacy_item "$supervisor_root/01_Admin" "$supervisor_root/01_admin"; then migrated=true; fi
  if move_legacy_item "$supervisor_root/01_admin/Registration" "$supervisor_root/01_admin/registration"; then migrated=true; fi
  if move_legacy_item "$supervisor_root/01_admin/Funding" "$supervisor_root/01_admin/funding"; then migrated=true; fi
  if move_legacy_item "$supervisor_root/01_admin/Progress_Reports" "$supervisor_root/01_admin/progress_reports"; then migrated=true; fi
  if move_legacy_item "$supervisor_root/01_admin/Coursework" "$supervisor_root/01_admin/coursework"; then migrated=true; fi
  if move_legacy_item "$supervisor_root/01_admin/Candidacy" "$supervisor_root/01_admin/candidacy"; then migrated=true; fi
  if move_legacy_item "$supervisor_root/01_admin/Examiners" "$supervisor_root/01_admin/examiners"; then migrated=true; fi

  if [[ "$migrated" == true ]]; then
    NEEDS_TEMPLATE_REFRESH="true"
  fi

  while IFS= read -r subdir; do
    [[ -z "$subdir" ]] && continue
    ensure_directory "$shared_root/$subdir"
  done < <(shared_common_subdirs)

  case "$program" in
    Masters)
      while IFS= read -r subdir; do
        [[ -z "$subdir" ]] && continue
        ensure_directory "$shared_root/$subdir"
      done < <(masters_shared_extra_subdirs)
      ;;
    PhD)
      while IFS= read -r subdir; do
        [[ -z "$subdir" ]] && continue
        ensure_directory "$shared_root/$subdir"
      done < <(phd_shared_extra_subdirs)
      ;;
  esac

  while IFS= read -r subdir; do
    [[ -z "$subdir" ]] && continue
    ensure_directory "$supervisor_root/$subdir"
  done < <(supervisor_common_subdirs)

  case "$program" in
    Masters)
      while IFS= read -r subdir; do
        [[ -z "$subdir" ]] && continue
        ensure_directory "$supervisor_root/$subdir"
      done < <(masters_supervisor_extra_subdirs)
      ;;
    PhD)
      while IFS= read -r subdir; do
        [[ -z "$subdir" ]] && continue
        ensure_directory "$supervisor_root/$subdir"
      done < <(phd_supervisor_extra_subdirs)
      ;;
  esac

  create_student_readme "$student_root/README.md" "$full_name" "$program"
  create_shared_readme "$shared_root/README.md" "$full_name" "$program"
  create_supervisor_private_readme "$supervisor_root/private_workspace_overview.md" "$program"
  create_supervisor_quickstart "$student_root/supervision_quickstart.md" "$full_name" "$program" "$supervisor" "$co_supervisor"

  create_student_profile "$supervisor_root/01_admin/00_student_profile.md" "$full_name" "$program" "$start_year" "$supervisor" "$co_supervisor" "$notes"
  create_student_meeting_log "$shared_root/02_meetings/supervision_meetings.md"
  create_student_research_log "$shared_root/01_research/research_log.md"

  create_template_meeting_notes "$template_root/meeting-notes-template.md"
  create_template_progress_report "$template_root/progress-review-template.md" "$program"
  create_template_onboarding "$template_root/onboarding-checklist.md" "$program"

  NEEDS_TEMPLATE_REFRESH="false"
}

parse_student_spec() {
  local spec="$1"
  IFS='|' read -r raw_level raw_name raw_year raw_supervisor raw_co_supervisor raw_notes <<<"$spec"

  if [[ -z "${raw_level:-}" || -z "${raw_name:-}" ]]; then
    abort "--student requires at least level and full name"
  fi

  if ! STUDENT_PROGRAM="$(canonical_program "$(trim "$raw_level")")"; then
    abort "Unrecognised programme level: ${raw_level}"
  fi

  STUDENT_NAME="$(trim "${raw_name:-}")"
  STUDENT_YEAR="$(trim "${raw_year:-}")"
  STUDENT_SUPERVISOR="$(trim "${raw_supervisor:-}")"
  STUDENT_CO_SUPERVISOR="$(trim "${raw_co_supervisor:-}")"
  STUDENT_NOTES="$(trim "${raw_notes:-}")"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        [[ $# -lt 2 ]] && abort "--root requires a directory argument"
        ROOT_DIR="$2"
        shift 2
        ;;
      --student)
        [[ $# -lt 2 ]] && abort "--student requires a specification string"
        STUDENT_SPEC="$2"
        shift 2
        ;;
      --folder-name)
        [[ $# -lt 2 ]] && abort "--folder-name requires a value"
        CUSTOM_FOLDER_NAME="$2"
        shift 2
        ;;
      --cleanup)
        CLEANUP_MODE="true"
        shift 1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        abort "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  [[ -z "$STUDENT_SPEC" ]] && abort "Missing required --student specification"

  parse_student_spec "$STUDENT_SPEC"

  STUDENT_SLUG="$(slugify_name "$STUDENT_NAME")"
  PROGRAM_SLUG="$(program_slug_from_name "$STUDENT_PROGRAM")"
  SHARED_DIR="$(derive_shared_dir_name "$STUDENT_PROGRAM" "$STUDENT_SLUG")"
  SUPERVISOR_DIR="supervisor_private"
  PRIVATE_TEMPLATE_DIR="${SUPERVISOR_DIR}/02_templates"

  ensure_directory "$ROOT_DIR"

  local folder_name
  folder_name="${CUSTOM_FOLDER_NAME:-$(derive_student_folder_name "$STUDENT_PROGRAM" "$STUDENT_NAME" "$STUDENT_YEAR")}"
  local student_root="$ROOT_DIR/$folder_name"

  if [[ "$CLEANUP_MODE" == "true" ]]; then
    if cleanup_student_structure "$student_root"; then
      if [[ -n "$LAST_BACKUP_DIR" ]]; then
        log "Cleanup complete. Retained items moved to: $LAST_BACKUP_DIR"
      else
        log "Cleanup complete. Workspace directory cleared."
      fi
    fi
    return
  fi

  create_student_structure "$student_root" "$STUDENT_PROGRAM" "$STUDENT_NAME" "$STUDENT_YEAR" "$STUDENT_SUPERVISOR" "$STUDENT_CO_SUPERVISOR" "$STUDENT_NOTES"

  log "Supervision workspace ready: $student_root"
}

main "$@"
