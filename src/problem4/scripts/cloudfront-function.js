// CloudFront Function (attach as ORIGIN-REQUEST on the S3-origin behavior).
//
// Release layout: releases/<tag>/... + KeyValueStore keys "current"/"previous".
// Every request path is rewritten to the live release directory, so the
// bucket root itself is never served and releases are switched atomically
// by updating the KVS key.
import cf from "cloudfront";

const kvsHandle = cf.kvs();

async function handler(event) {
  const request = event.request;
  const uri = request.uri;

  if (uri.startsWith("/releases/") || uri.startsWith("/current") || uri.startsWith("/previous")) {
    return request;
  }

  let current = "";
  try {
    current = await kvsHandle.get("current");
  } catch (err) {
    return request;
  }
  if (!current) {
    return request;
  }

  request.uri = "/releases/" + current + (uri === "/" ? "/index.html" : uri);
  return request;
}
