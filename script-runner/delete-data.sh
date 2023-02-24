#!/bin/sh

function deleteInfluxdbBucket() {
  bucketId=$(
    curl --silent --header "Authorization: Token ${DB_TOKEN}" --header "Accept: application/json" "${DB_URL}/api/v2/buckets?name=${DB_BUCKET}" |
      jq -r ".buckets[0].id"
  )

  curl --request DELETE \
    --silent \
    --header "Authorization: Token ${DB_TOKEN}" \
    --header "Content-type: application/json" \
    "${DB_URL}/api/v2/buckets/${bucketId}"
}

############
### MAIN ###
############
DB_URL=http://influxdb:8086
DB_TOKEN=$DOCKER_SCRIPTRUNNER_INFLUXDB_TOKEN
DB_BUCKET=$DOCKER_SCRIPTRUNNER_INFLUXDB_BUCKET

echo "Delete bucket ${DB_BUCKET}"
deleteInfluxdbBucket
