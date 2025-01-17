#!/bin/bash
project_arn=$DEVICEFARM_PROJECT_ARN
device_pool_arn=$DEVICEFARM_POOL_ARN
module_name=$1
file_name="$module_name-debug-androidTest.apk"
full_path="$module_name/build/outputs/apk/androidTest/debug/$file_name"

if [[ -z "${project_arn}" ]]; then
  echo "DEVICEFARM_PROJECT_ARN environment variable not set."
  exit 1
fi
if [[ -z "${device_pool_arn}" ]]; then
  echo "DEVICEFARM_POOL_ARN environment variable not set."
  exit 1
fi

# Function to setup the app uploads in device farm
function createUpload {
  test_type=$1
  upload_response=`aws devicefarm create-upload --type $test_type \
                             --content-type="application/octet-stream" \
                             --project-arn="$project_arn" \
                             --name="$file_name" \
                             --query="upload.[url, arn]" \
                             --region="us-west-2" \
                             --output=text`
  echo $upload_response
}

echo 'Uploading test package'
# Create an upload for the instrumentation test package
read -a result <<< $(createUpload "INSTRUMENTATION_TEST_PACKAGE")
test_package_url=${result[0]}
test_package_upload_arn=${result[1]}
# Upload the apk
curl -H "Content-Type:application/octet-stream" -T $full_path $test_package_url

# Create an upload for the app package (They're the same, but they have to be setup in device farm)
echo 'Uploading app package'
read -a result <<< $(createUpload "ANDROID_APP")
app_package_url=${result[0]}
app_package_upload_arn=${result[1]}
# Upload the apk
curl -H "Content-Type:application/octet-stream" -T $full_path $app_package_url

# Wait to make sure the upload completes. This should actually make a get-upload call and check the status.
echo "Waiting for uploads to complete"
sleep 10

run_name="$file_name-Nightly-$CODEBUILD_SOURCE_VERSION"
# Function to cancel duplicate runs for same code source in device farm.
function stopDuplicates {
  echo "Stopping duplicate runs"
  read -a running_arns <<< $(aws devicefarm list-runs \
                          --arn="$project_arn" \
                          --query="runs[?(status == 'RUNNING' || status == 'PENDING')  && name == '${run_name}'].arn" \
                          --region="us-west-2" \
                          --max-items=5 \
                          | jq -r '.[]')

  for arn in "${running_arns[@]}"
  do
    ## Just consume the result and do nothing with it.
    result=`aws devicefarm stop-run --arn $arn --region="us-west-2" --query="run.name"`
  done
}
stopDuplicates

# Select range of devices from version 7 and above.
device1=$(aws devicefarm list-devices \
                --region="us-west-2" \
                --filters '[
                    {"attribute":"AVAILABILITY","operator":"EQUALS","values":["HIGHLY_AVAILABLE"]},
                    {"attribute":"PLATFORM","operator":"EQUALS","values":["ANDROID"]},
                    {"attribute":"OS_VERSION","operator":"GREATER_THAN_OR_EQUALS","values":["7"]},
                    {"attribute":"OS_VERSION","operator":"LESS_THAN","values":["7.1"]},
                    {"attribute":"MANUFACTURER","operator":"IN","values":["Google", "Pixel", "Samsung"]}
                ]' \
                | jq -r '.devices[0].arn')

device2=$(aws devicefarm list-devices \
                --region="us-west-2" \
                --filters '[
                    {"attribute":"AVAILABILITY","operator":"EQUALS","values":["HIGHLY_AVAILABLE"]},
                    {"attribute":"PLATFORM","operator":"EQUALS","values":["ANDROID"]},
                    {"attribute":"OS_VERSION","operator":"GREATER_THAN_OR_EQUALS","values":["8"]},
                    {"attribute":"OS_VERSION","operator":"LESS_THAN","values":["9"]},
                    {"attribute":"MANUFACTURER","operator":"IN","values":["Samsung"]}
                ]' \
                | jq -r '.devices[0].arn')

device3=$(aws devicefarm list-devices \
                --region="us-west-2" \
                --filters '[
                    {"attribute":"ARN","operator":"NOT_IN","values":["'$device2'"]},
                    {"attribute":"AVAILABILITY","operator":"EQUALS","values":["HIGHLY_AVAILABLE"]},
                    {"attribute":"PLATFORM","operator":"EQUALS","values":["ANDROID"]},
                    {"attribute":"OS_VERSION","operator":"GREATER_THAN_OR_EQUALS","values":["9"]},
                    {"attribute":"OS_VERSION","operator":"LESS_THAN","values":["10"]},
                    {"attribute":"MANUFACTURER","operator":"IN","values":["Samsung"]}
                ]' \
                | jq -r '.devices[0].arn')

device4=$(aws devicefarm list-devices \
                --region="us-west-2" \
                --filters '[
                    {"attribute":"ARN","operator":"NOT_IN","values":["'$device2'", "'$device3'"]},
                    {"attribute":"AVAILABILITY","operator":"EQUALS","values":["HIGHLY_AVAILABLE"]},
                    {"attribute":"PLATFORM","operator":"EQUALS","values":["ANDROID"]},
                    {"attribute":"OS_VERSION","operator":"GREATER_THAN_OR_EQUALS","values":["10"]},
                    {"attribute":"OS_VERSION","operator":"LESS_THAN","values":["11"]},
                    {"attribute":"MANUFACTURER","operator":"IN","values":["Samsung"]}
                ]' \
                | jq -r '.devices[0].arn')

device5=$(aws devicefarm list-devices \
                --region="us-west-2" \
                --filters '[
                    {"attribute":"AVAILABILITY","operator":"EQUALS","values":["HIGHLY_AVAILABLE"]},
                    {"attribute":"PLATFORM","operator":"EQUALS","values":["ANDROID"]},
                    {"attribute":"OS_VERSION","operator":"GREATER_THAN_OR_EQUALS","values":["12"]},
                    {"attribute":"MANUFACTURER","operator":"IN","values":["Google", "Pixel"]}
                ]' \
                | jq -r '.devices[0].arn')

# IF we fail to find our required test devices, fail.
if [[ -z "${device1}" || -z "${device2}" || -z "${device3}" || -z "${device4}" || -z "${device5}" ]]; then
    echo "Failed to grab 5 required devices for integration tests."
    exit 1
fi

# Schedule the test run in device farm
echo "Scheduling test run"
run_arn=`aws devicefarm schedule-run --project-arn=$project_arn \
                            --app-arn="$app_package_upload_arn" \
                            --device-selection-configuration='{
                                "filters": [
                                  {"attribute": "ARN", "operator":"IN", "values":["'$device1'", "'$device2'", "'$device3'", "'$device4'", "'$device5'"]}
                                ],
                                "maxDevices": '5'
                            }' \
                            --name="$run_name" \
                            --test="type=INSTRUMENTATION,testPackageArn=$test_package_upload_arn" \
                            --execution-configuration="jobTimeoutMinutes=30,videoCapture=false" \
                            --query="run.arn" \
                            --output=text \
                            --region="us-west-2"`

status='NONE'
result='NONE'
# Wait for the test to complete
while true; do
  run_status_response=`aws devicefarm get-run --arn="$run_arn" --region="us-west-2" --query="run.[status, result]" --output text`
  read -a result_arr <<< $run_status_response
  status=${result_arr[0]}
  result=${result_arr[1]}
  if [ "$status" = "COMPLETED" ]
  then
    break
  fi
  sleep 5
done
echo "Status = $status Result = $result"

./scripts/generate_df_testrun_report --run_arn="$run_arn" --module_name="$module_name" --pr="$CODEBUILD_SOURCE_VERSION" --output_path="build/allTests/$module_name/"
# If the result is PASSED, then exit with a return code 0
if [ "$result" = "PASSED" ]
then
  exit 0
fi
# Otherwise, exit with a non-zero.
exit 1
