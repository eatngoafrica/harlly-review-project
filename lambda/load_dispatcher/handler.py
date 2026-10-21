"""Load dispatcher: SQS (extract success messages) -> starts the Glue load job.

Each message is one extract run. The load job runs one at a time; while one is
running, start_job_run fails, the message goes back on the queue and is retried
after the visibility timeout. A message that keeps failing ends up in the
dead-letter queue, which raises an alarm.
"""

import json
import os

import boto3

glue = boto3.client("glue")
LOAD_JOB_NAME = os.environ["LOAD_JOB_NAME"]


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        message = json.loads(record["body"])
        if message.get("Type") == "Notification":  # SNS envelope, if raw delivery is off
            message = json.loads(message["Message"])
        if not message.get("has_changes", True):
            print(f"{message.get('run')}: nothing changed, no load needed")
            continue
        try:
            response = glue.start_job_run(JobName=LOAD_JOB_NAME, Arguments={
                "--MANIFEST": message["manifest"], "--ATTEMPT": str(message.get("attempt", 1))})
            print(f"{message.get('run')}: started {LOAD_JOB_NAME} run {response['JobRunId']}")
        except glue.exceptions.ConcurrentRunsExceededException:
            print(f"{message.get('run')}: a load is already running; will retry")
            failures.append({"itemIdentifier": record["messageId"]})
    # Only the failed messages go back on the queue.
    return {"batchItemFailures": failures}
