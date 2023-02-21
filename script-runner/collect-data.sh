#!/bin/sh

function createInfluxdbBucket() {
  orgId=$(curl --silent --header "Authorization: Token ${DB_TOKEN}" --header "Accept: application/json" "${DB_URL}/api/v2/orgs" |
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
    buildScanIds=$(curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds?fromInstant=${fromInstant}&reverse=false&maxBuilds=1000" |
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

    isAlreadyProcessed="false"
    isBuildProcessed ${buildScanId}
    if [ "${isAlreadyProcessed}" == "true" ]
    then
        echo "Skipping build (already processed)"
        return
    fi

    buildScanData=""
    if [ "${buildType}" == "gradle" ]
    then
        buildScanData=$(curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-attributes" |
                           jq "{buildStartTime, values, projectName: .rootProjectName}"
                       )
    else
        buildScanData=$(curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-attributes" |
                           jq "{buildStartTime, values, projectName: .topLevelProjectName}"
                       )
    fi
    buildStartTime=$(echo ${buildScanData} | jq .buildStartTime)
    customValues=$(echo ${buildScanData} | jq -c .values)
    currentProject=$(echo ${buildScanData} | jq -r .projectName)

    isMatching=false
    isMatchingProject "${currentProject}"
    if [ "$isMatching" == "false" ]
    then
        echo "Skipping build (not matching project)"
        return
    fi

    isMatching=false
    isMatchingCustomValue "${customValues}"
    if [ "$isMatching" == "false" ]
    then
        echo "Skipping build (not matching custom value)"
        return
    fi

    local tasks=""
    if [ "${buildType}" == "gradle" ]
    then
        tasks=$(curl --silent --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-build-cache-performance" |
                   jq -c ".taskExecution[] | {task: .taskPath,type: .taskType,duration,avoidanceOutcome}"
               )
    else
        tasks=$(curl -s --header "authorization: Bearer ${geToken}" "${geUrl}/api/builds/${buildScanId}/${buildType}-build-cache-performance" |
                   jq -c ".goalExecution[] | {task: .goalName,type: .mojoType,duration,avoidanceOutcome}"
               )
    fi

    if [ ! -z "${tasks}" ]
    then
        for task in ${tasks}; do
            taskName=$(echo ${task} | jq -r .task)
            taskType=$(echo ${task} | jq -r .type)
            duration=$(echo ${task} | jq -r .duration)
            avoidanceOutcome=$(echo ${task} | jq -r .avoidanceOutcome)
            echo "Adding record for ${buildScanId} [task,buildScanId=${buildScanId},avoidanceOutcome=${avoidanceOutcome},taskName=${taskName},taskType=${taskType} duration=${duration} ${buildStartTime}]"
            httpStatus=$(curl --request POST \
                          --silent \
                          --write-out '%{http_code}' \
                          --output /dev/null \
                          --header "Authorization: Token ${DB_TOKEN}" \
                          "${DB_URL}/write?org=${DB_ORG}&db=${DB_BUCKET}&precision=ms" \
                          --data-binary "task,buildScanId=${buildScanId},avoidanceOutcome=${avoidanceOutcome},taskName=${taskName},taskType=${taskType} duration=${duration} ${buildStartTime}"
                        )
            if [[ "$httpStatus" != "204" ]] ; then
                echo "Adding record failed [$httpStatus]"
                break
            fi
        done
    fi
}

function isBuildProcessed() {
    local buildScanId=$1

    recordCount=$(curl --silent -X POST "${DB_URL}/api/v2/query?org=${DB_ORG}" \
                      --header 'Content-Type: application/vnd.flux' \
                      --header "Authorization: Token ${DB_TOKEN}" \
                      --data "from(bucket: \"${DB_BUCKET}\")
                                |> range(start: -1w)
                                |> filter(fn: (r) => exists r.buildScanId and r.buildScanId == \"${buildScanId}\")" | wc -l
                    )
    if [ "${recordCount}" != "1" ]
    then
        isAlreadyProcessed="true"
    fi
}

function isMatchingProject() {
    local currentProject=$1

    if [ ! -z "${projectFilter}" ]
    then
      if [ "${projectFilter}" == "${currentProject}" ]
      then
          isMatching=true
      fi
    else
        isMatching=true
    fi
}

function isMatchingCustomValue() {
    local customValues=$1

    if [ ! -z "${customValueFilter}" ]
    then
        customKey=$(echo ${customValueFilter} | cut -d "=" -f 1)
        customValue=$(echo ${customValueFilter} | cut -d "=" -f 2)
        isMatching=$(echo ${customValues} |
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

geUrl=$1
geToken=$2
fromInstant=$3
projectFilter=$4
customValueFilter=$5

echo "Looking for builds since $(date -d @${fromInstant})"
if [ ! -z "${projectFilter}" ]
then
    echo "Filtering builds from project (${projectFilter})"
fi
if [ ! -z "${customValueFilter}" ]
then
    echo "Filtering builds matching custom value (${customValueFilter})"
fi

# Create bucket
createInfluxdbBucket

# Process Gradle builds
getBuilds gradle
processBuilds gradle

# Process Maven builds
getBuilds maven
processBuilds maven