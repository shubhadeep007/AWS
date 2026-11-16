"""Order notification worker: SQS -> SES.

Triggered by the notifications queue (fed by the order-events SNS topic with raw
message delivery). Safe to retry: SQS delivers at least once, so every message is
claimed in DynamoDB before an email is sent.

Expected message body (JSON):
    {
      "order_id": "ORD-1001",
      "event_type": "order_placed",
      "customer_email": "asha@example.com",
      "customer_name": "Asha",
      "total": "2499.00",
      "currency": "INR",
      "items": [{"name": "Linen shirt", "qty": 1}]
    }
The event type may also arrive as the SQS message attribute "event_type".
"""

import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

ses = boto3.client("sesv2")
dynamodb = boto3.client("dynamodb")

FROM_EMAIL = os.environ["FROM_EMAIL"]
CONFIG_SET = os.environ.get("CONFIG_SET")
IDEMPOTENCY_TABLE = os.environ["IDEMPOTENCY_TABLE"]
DEDUPE_TTL_SECONDS = 7 * 24 * 3600

SUBJECTS = {
    "order_placed": "We got your order {order_id}",
    "order_shipped": "Your order {order_id} is on its way",
    "order_delivered": "Your order {order_id} was delivered",
    "order_cancelled": "Your order {order_id} was cancelled",
}

HEADLINES = {
    "order_placed": "Thanks for your order!",
    "order_shipped": "Good news, your order has shipped.",
    "order_delivered": "Your order has been delivered.",
    "order_cancelled": "Your order has been cancelled.",
}


def lambda_handler(event, context):
    """Return only the failed message IDs so SQS retries just those."""
    failures = []
    for record in event.get("Records", []):
        try:
            _process(record)
        except Exception:  # noqa: BLE001 - any failure must trigger a retry
            # Log the message ID, never the body: it contains customer PII.
            logger.exception("Failed to process message %s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


def _process(record):
    body = json.loads(record["body"])
    attributes = record.get("messageAttributes") or {}
    event_type = body.get("event_type") or attributes.get("event_type", {}).get("stringValue")

    if event_type not in SUBJECTS:
        # Unknown event: nothing to send. Returning normally deletes the message.
        logger.warning("Ignoring unsupported event_type=%s", event_type)
        return

    order_id = body["order_id"]
    to_address = body["customer_email"]
    dedupe_key = f"notify#{order_id}#{event_type}"

    if not _claim(dedupe_key):
        logger.info("Duplicate suppressed for order %s (%s)", order_id, event_type)
        return

    try:
        _send_email(event_type, order_id, to_address, body)
    except Exception:
        # Release the claim so the retry is allowed to send.
        _release(dedupe_key)
        raise

    logger.info("Sent %s email for order %s", event_type, order_id)


def _claim(key):
    """True the first time a key is seen, False for duplicates."""
    try:
        dynamodb.put_item(
            TableName=IDEMPOTENCY_TABLE,
            Item={
                "idempotency_key": {"S": key},
                "expires_at": {"N": str(int(time.time()) + DEDUPE_TTL_SECONDS)},
            },
            ConditionExpression="attribute_not_exists(idempotency_key)",
        )
        return True
    except ClientError as err:
        if err.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _release(key):
    dynamodb.delete_item(
        TableName=IDEMPOTENCY_TABLE,
        Key={"idempotency_key": {"S": key}},
    )


def _send_email(event_type, order_id, to_address, body):
    name = body.get("customer_name") or "there"
    lines = [f"- {item.get('qty', 1)} x {item.get('name', 'item')}" for item in body.get("items", [])]
    total = body.get("total")
    currency = body.get("currency", "INR")

    text = "\n".join(
        [
            f"Hi {name},",
            "",
            HEADLINES[event_type],
            f"Order: {order_id}",
            *lines,
            f"Total: {currency} {total}" if total else "",
            "",
            "Thank you for shopping with us.",
        ]
    )

    params = {
        "FromEmailAddress": FROM_EMAIL,
        "Destination": {"ToAddresses": [to_address]},
        "Content": {
            "Simple": {
                "Subject": {"Data": SUBJECTS[event_type].format(order_id=order_id), "Charset": "UTF-8"},
                "Body": {"Text": {"Data": text, "Charset": "UTF-8"}},
            }
        },
    }
    if CONFIG_SET:
        params["ConfigurationSetName"] = CONFIG_SET

    ses.send_email(**params)
