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
  local buildType=$1
  buildScanIds=$(
    curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds?fromInstant=${fromInstant}&reverse=false&maxBuilds=1000" |
      jq -r ".[] | select( .buildToolType == \"${buildType}\") | .id"
  )
}

function processBuilds() {
  local buildType=$1
  for buildScanId in ${buildScanIds}; do
    echo "Processing ${buildType} build ${buildScanId}"
    processBuild ${buildType} ${buildScanId}
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

  local buildScanData=$(
    curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-attributes" |
      jq --arg projectKey "${projectKey}" "{buildStartTime, values, projectName: $projectKey}"
  )
  local buildStartTime=$(echo ${buildScanData} | jq .buildStartTime)
  local customValues=$(echo ${buildScanData} | jq -c .values)
  local currentProject=$(echo ${buildScanData} | jq -r .projectName)

  isMatching=false
  isMatchingProject "${currentProject}"
  if [ "$isMatching" == "false" ]; then
    echo "Skipping build (not matching project)"
    return
  fi

  isMatching=false
  isMatchingCustomValue "${customValues}"
  if [ "$isMatching" == "false" ]; then
    echo "Skipping build (not matching custom value)"
    return
  fi

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

function isMatchingProject() {
  local currentProject=$1

  if [ ! -z "${projectFilter}" ]; then
    if [ "${projectFilter}" == "${currentProject}" ]; then
      isMatching=true
    fi
  else
    isMatching=true
  fi
}

function isMatchingCustomValue() {
  local customValues=$1

  if [ ! -z "${customValueFilter}" ]; then
    customKey=$(echo ${customValueFilter} | cut -d "=" -f 1)
    customValue=$(echo ${customValueFilter} | cut -d "=" -f 2)
    isMatching=$(
      echo ${customValues} |
        jq --arg customKey "${customKey}" --arg customValue "${customValue}" 'contains([{name:$customKey,value:$customValue}])'
    )
  else
    isMatching=true
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
  echo 'USAGE: "collect-data.sh <GRADLE_ENTERPRISE_URL> <GRADLE_ENTERPRISE_TOKEN> <FROM_INSTANT_UNIX_TIMESTAMP_IN_MS> [--project <PROJECT>] [--custom-value "<KEY=VALUE>"]'
  exit 1
fi

geUrl=$1
geToken=$2
fromInstant=$3

while :; do
  case $4 in
  -p | --project)
    if [ "$5" ]; then
      projectFilter=$5
      shift
    else
      echo 'ERROR: "--project" requires a non-empty option argument.'
      exit 1
    fi
    ;;
  -c | --custom-value)
    customValueFilter=$4
    if [ "$5" ]; then
      customValueFilter=$5
      shift
    else
      echo 'ERROR: "--custom-value" requires a non-empty option argument.'
      exit 1
    fi
    ;;
  *) break ;;
  esac
  shift
done

echo "Looking for builds since $(date -d @${fromInstant})"
if [ ! -z "${projectFilter}" ]; then
  echo "Filtering builds from project (${projectFilter})"
fi
if [ ! -z "${customValueFilter}" ]; then
  echo "Filtering builds matching custom value (${customValueFilter})"
fi

# Create bucket
createInfluxdbBucket

# Process Gradle builds
buildScanIds=""
getBuilds gradle
processBuilds gradle

# Process Maven builds
buildScanIds=""
getBuilds maven
processBuilds maven
