#!/usr/bin/env bash
set -euo pipefail

# --- Color Definitions ---
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")

# --- UI Helpers ---
log_task() {
  echo -e "\n${CYAN}${BOLD}[*] $1${RESET}"
}

log_success() {
  echo -e "${GREEN}${BOLD}[✔] $1${RESET}\n"
}

log_info() {
  echo -e "${YELLOW}${BOLD}--> $1${RESET}"
}

prompt_input() {
  local prompt_label="$1"
  local var_name="$2"
  local val=""
  while [[ -z "$val" ]]; do
    read -rp "  ${BLUE}➜${RESET} ${prompt_label}: " val
    if [[ -z "$val" ]]; then
      echo -e "    ${RED}Value cannot be empty. Please retry.${RESET}"
    fi
  done
  printf -v "$var_name" '%s' "$val"
}

# --- Banner ---
clear
echo -e "${BLUE}${BOLD}============================================="
echo -e "       SOCCER ANALYTICS AUTOMATION          "
echo -e "=============================================${RESET}\n"

# --- Collect Inputs ---
echo -e "${BOLD}Please enter the required pipeline parameters:${RESET}"
prompt_input "Enter EVENT_NAME"   EVENT_NAME
prompt_input "Enter TABLE_NAME"   TABLE_NAME
prompt_input "Enter VALUE_X_1"    VALUE_X_1
prompt_input "Enter VALUE_Y_1"    VALUE_Y_1
prompt_input "Enter VALUE_X_2"    VALUE_X_2
prompt_input "Enter VALUE_Y_2"    VALUE_Y_2
prompt_input "Enter FUNCTION_1"   FUNCTION_1
prompt_input "Enter FUNCTION_2"   FUNCTION_2
prompt_input "Enter MODEL_NAME"   MODEL_NAME

log_info "Initializing environment and project configuration..."
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "$DEVSHELL_PROJECT_ID")
export DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$PROJECT_ID}"

# ==============================================================================
# TASK 1: Load Data into BigQuery
# ==============================================================================
log_task "Task 1: Loading raw datasets into BigQuery..."

bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect "${DEVSHELL_PROJECT_ID}:soccer.${EVENT_NAME}" gs://spls/bq-soccer-analytics/events.json
bq load --source_format=CSV --autodetect "${DEVSHELL_PROJECT_ID}:soccer.${TABLE_NAME}" gs://spls/bq-soccer-analytics/tags2name.csv
bq load --autodetect --source_format=NEWLINE_DELIMITED_JSON "${DEVSHELL_PROJECT_ID}:soccer.competitions" gs://spls/bq-soccer-analytics/competitions.json
bq load --autodetect --source_format=NEWLINE_DELIMITED_JSON "${DEVSHELL_PROJECT_ID}:soccer.matches" gs://spls/bq-soccer-analytics/matches.json
bq load --autodetect --source_format=NEWLINE_DELIMITED_JSON "${DEVSHELL_PROJECT_ID}:soccer.teams" gs://spls/bq-soccer-analytics/teams.json
bq load --autodetect --source_format=NEWLINE_DELIMITED_JSON "${DEVSHELL_PROJECT_ID}:soccer.players" gs://spls/bq-soccer-analytics/players.json
bq load --autodetect --source_format=NEWLINE_DELIMITED_JSON "${DEVSHELL_PROJECT_ID}:soccer.events" gs://spls/bq-soccer-analytics/events.json

log_success "Task 1 Completed: Tables loaded successfully."

# ==============================================================================
# TASK 2: Penalty Kick Analysis
# ==============================================================================
log_task "Task 2: Running Penalty Kick Success Analysis..."

bq query --use_legacy_sql=false \
"
SELECT
  playerId,
  (Players.firstName || ' ' || Players.lastName) AS playerName,
  COUNT(id) AS numPKAtt,
  SUM(IF(101 IN UNNEST(tags.id), 1, 0)) AS numPKGoals,
  SAFE_DIVIDE(
    SUM(IF(101 IN UNNEST(tags.id), 1, 0)),
    COUNT(id)
  ) AS PKSuccessRate
FROM
  \`soccer.${EVENT_NAME}\` Events
LEFT JOIN
  \`soccer.players\` Players ON Events.playerId = Players.wyId
WHERE
  eventName = 'Free Kick' AND subEventName = 'Penalty'
GROUP BY
  playerId, playerName
HAVING
  numPkAtt >= 5
ORDER BY
  PKSuccessRate DESC, numPKAtt DESC;
"

log_success "Task 2 Completed."

# ==============================================================================
# TASK 3: Shot Distance Calculations
# ==============================================================================
log_task "Task 3: Aggregating Shot Distance and Success Rate..."

bq query --use_legacy_sql=false \
"
WITH Shots AS (
  SELECT
    *,
    (101 IN UNNEST(tags.id)) AS isGoal,
    SQRT(
      POW((100 - positions[ORDINAL(1)].x) * ${VALUE_X_1} / ${VALUE_Y_1}, 2) +
      POW((60 - positions[ORDINAL(1)].y) * ${VALUE_X_2} / ${VALUE_Y_2}, 2)
    ) AS shotDistance
  FROM
    \`soccer.${EVENT_NAME}\`
  WHERE
    eventName = 'Shot' OR
    (eventName = 'Free Kick' AND subEventName IN ('Free kick shot', 'Penalty'))
)
SELECT
  ROUND(shotDistance, 0) AS ShotDistRound0,
  COUNT(*) AS numShots,
  SUM(IF(isGoal, 1, 0)) AS numGoals,
  AVG(IF(isGoal, 1, 0)) AS goalPct
FROM
  Shots
WHERE
  shotDistance <= 50
GROUP BY
  ShotDistRound0
ORDER BY
  ShotDistRound0;
"

log_success "Task 3 Completed."

# ==============================================================================
# TASK 4: Model Training
# ==============================================================================
log_task "Task 4: Training Logistic Regression Model (${MODEL_NAME})..."

bq query --use_legacy_sql=false \
"
CREATE OR REPLACE MODEL \`${MODEL_NAME}\`
OPTIONS(
  model_type = 'LOGISTIC_REG',
  input_label_cols = ['isGoal']
) AS
SELECT
  Events.subEventName AS shotType,
  (101 IN UNNEST(Events.tags.id)) AS isGoal,
  \`${FUNCTION_1}\`(Events.positions[ORDINAL(1)].x, Events.positions[ORDINAL(1)].y) AS shotDistance,
  \`${FUNCTION_2}\`(Events.positions[ORDINAL(1)].x, Events.positions[ORDINAL(1)].y) AS shotAngle
FROM
  \`soccer.${EVENT_NAME}\` Events
LEFT JOIN
  \`soccer.matches\` Matches ON Events.matchId = Matches.wyId
LEFT JOIN
  \`soccer.competitions\` Competitions ON Matches.competitionId = Competitions.wyId
WHERE
  Competitions.name != 'World Cup' AND
  (
    eventName = 'Shot' OR
    (eventName = 'Free Kick' AND subEventName IN ('Free kick shot', 'Penalty'))
  ) AND
  \`${FUNCTION_2}\`(Events.positions[ORDINAL(1)].x, Events.positions[ORDINAL(1)].y) IS NOT NULL;
"

log_success "Task 4 Completed."

# ==============================================================================
# TASK 5: Model Predictions
# ==============================================================================
log_task "Task 5: Evaluating Predictions on World Cup Matches..."

bq query --use_legacy_sql=false \
"
SELECT
  predicted_isGoal_probs[ORDINAL(1)].prob AS predictedGoalProb,
  * EXCEPT (predicted_isGoal, predicted_isGoal_probs)
FROM
  ML.PREDICT(
    MODEL \`${MODEL_NAME}\`,
    (
      SELECT
        Events.playerId,
        (Players.firstName || ' ' || Players.lastName) AS playerName,
        Teams.name AS teamName,
        CAST(Matches.dateutc AS DATE) AS matchDate,
        Matches.label AS match,
        CAST(
          (CASE
            WHEN Events.matchPeriod = '1H' THEN 0
            WHEN Events.matchPeriod = '2H' THEN 45
            WHEN Events.matchPeriod = 'E1' THEN 90
            WHEN Events.matchPeriod = 'E2' THEN 105
            ELSE 120
          END) + CEILING(Events.eventSec / 60) AS INT64
        ) AS matchMinute,
        Events.subEventName AS shotType,
        (101 IN UNNEST(Events.tags.id)) AS isGoal,
        \`soccer.${FUNCTION_1}\`(Events.positions[ORDINAL(1)].x, Events.positions[ORDINAL(1)].y) AS shotDistance,
        \`soccer.${FUNCTION_2}\`(Events.positions[ORDINAL(1)].x, Events.positions[ORDINAL(1)].y) AS shotAngle
      FROM
        \`soccer.${EVENT_NAME}\` Events
      LEFT JOIN
        \`soccer.matches\` Matches ON Events.matchId = Matches.wyId
      LEFT JOIN
        \`soccer.competitions\` Competitions ON Matches.competitionId = Competitions.wyId
      LEFT JOIN
        \`soccer.players\` Players ON Events.playerId = Players.wyId
      LEFT JOIN
        \`soccer.teams\` Teams ON Events.teamId = Teams.wyId
      WHERE
        Competitions.name = 'World Cup' AND
        (
          eventName = 'Shot' OR
          (eventName = 'Free Kick' AND subEventName IN ('Free kick shot'))
        ) AND
        (101 IN UNNEST(Events.tags.id))
    )
  )
ORDER BY
  predictedGoalProb;
"

log_success "Task 5 Completed."

# --- Completion ---
echo -e "${GREEN}${BOLD}============================================="
echo -e "        ALL LAB TASKS COMPLETED!             "
echo -e "=============================================${RESET}"

exit 0
