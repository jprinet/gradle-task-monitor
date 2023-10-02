#!/bin/sh

function createInfluxdbBucket() {
  local orgId=$(
    curl --silent --header "Authorization: Token ${DB_TOKEN}" --header "Accept: application/json" "${DB_URL}/api/v2/orgs" |
      jq -r ".orgs[0].id"
  )

  curl --request POST \
    --silent \
    --header "Authorization: Token ${DB_TOKEN}" \
    --header "Content-type: application/json" \
    --output /dev/null \
    "${DB_URL}/api/v2/buckets" \
    --data "{
      \"orgID\": \"${orgId}\",
      \"name\": \"${DB_BUCKET}\",
      \"retentionRules\": [
        {
          \"type\": \"expire\",
          \"everySeconds\": ${DB_RETENTION},
          \"shardGroupDurationSeconds\": 0
        }
      ]
    }"
}

function getBuilds() {
  local encodedQuery=$(echo $query | jq -sRr @uri)
  buildScans=$(curl --silent "${geUrl}/api/builds?fromInstant=0&maxBuilds=1000&reverse=false&query=${encodedQuery}" --header "authorization: Bearer ${geToken}" | jq -r ".[] | [.id,.availableAt,.buildToolType] | @csv")
}

function processBuilds() {
  buildCount=1
  for buildScan in ${buildScans}; do
    # Remove "
    buildScan=$(echo "${buildScan}" | sed -e 's/"//g')

    # Parse fields
    buildScanId=$(echo "${buildScan}" | cut -d, -f 1)
    buildScanDate=$(echo "${buildScan}" | cut -d, -f 2)
    buildTool=$(echo "${buildScan}" | cut -d, -f 3)

    # process build
    echo "Build ${buildCount}: Processing ${buildScanId} (${buildTool}) published at $(date -d @$(echo ${buildScanDate} | head -c 10))"
    processBuild ${buildTool} ${buildScanId}

    buildCount=$((buildCount+1))
  done
}

function processBuild() {
  local buildType=$1
  local buildScanId=$2
  local projectKey=""
  local taskKey=""

  if [ "${buildType}" == "gradle" ]; then
    projectKey=".rootProjectName"
    taskKey=".taskPath"
  else
    projectKey=".topLevelProjectName"
    taskKey=".goalName"
  fi

  isAlreadyProcessed="false"
  isBuildProcessed ${buildScanId}
  if [ "${isAlreadyProcessed}" == "true" ]; then
    echo "Skipping build (already processed)"
    return
  fi

  local buildStartTime=$(
    curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-attributes" |
      jq .buildStartTime
  )

  local tasks=$(
    curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-build-cache-performance" |
      jq --arg taskKey "${taskKey}" -c ".taskExecution[] | {task: $taskKey,type: .taskType,duration,avoidanceOutcome}"
  )
  if [ ! -z "${tasks}" ]; then
    for task in ${tasks}; do
      local taskName=$(echo ${task} | jq -r .task)
      local taskType=$(echo ${task} | jq -r .type)
      local duration=$(echo ${task} | jq -r .duration)
      local avoidanceOutcome=$(echo ${task} | jq -r .avoidanceOutcome)
      echo "Adding record for ${buildScanId} [task,buildScanId=${buildScanId},avoidanceOutcome=${avoidanceOutcome},taskName=${taskName},taskType=${taskType} duration=${duration} ${buildStartTime}]"
      httpStatus=$(
        curl --request POST \
          --silent \
          --write-out '%{http_code}' \
          --output /dev/null \
          --header "Authorization: Token ${DB_TOKEN}" \
          "${DB_URL}/write?org=${DB_ORG}&db=${DB_BUCKET}&precision=ms" \
          --data-binary "task,buildScanId=${buildScanId},avoidanceOutcome=${avoidanceOutcome},taskName=${taskName},taskType=${taskType} duration=${duration} ${buildStartTime}"
      )
      if [ "$httpStatus" != "204" ]; then
        echo "Adding record failed [$httpStatus]"
        break
      fi
    done
  fi
}

function isBuildProcessed() {
  local buildScanId=$1

  recordCount=$(
    curl --silent -X POST "${DB_URL}/api/v2/query?org=${DB_ORG}" \
      --header 'Content-Type: application/vnd.flux' \
      --header "Authorization: Token ${DB_TOKEN}" \
      --data "from(bucket: \"${DB_BUCKET}\")
                                |> range(start: -1w)
                                |> filter(fn: (r) => exists r.buildScanId and r.buildScanId == \"${buildScanId}\")" | wc -l
  )
  if [ "${recordCount}" != "1" ]; then
    isAlreadyProcessed="true"
  fi
}

############
### MAIN ###
############
DB_URL=http://influxdb:8086
DB_ORG=$DOCKER_SCRIPTRUNNER_INFLUXDB_ORG
DB_BUCKET=$DOCKER_SCRIPTRUNNER_INFLUXDB_BUCKET
DB_TOKEN=$DOCKER_SCRIPTRUNNER_INFLUXDB_TOKEN
DB_RETENTION=$DOCKER_SCRIPTRUNNER_INFLUXDB_RETENTION_IN_SECONDS

if [ $# -lt 3 ]; then
  echo 'USAGE: "collect-data.sh <GRADLE_ENTERPRISE_URL> <GRADLE_ENTERPRISE_TOKEN> <query>'
  exit 1
fi

geUrl=$1
geToken=$2
query=$3

# Create bucket
createInfluxdbBucket

# Collect builds
getBuilds

# Process builds
processBuilds
