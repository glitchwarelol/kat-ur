const MAX_REQUEST_BYTES = 32 * 1024;
const MAX_RECIPE_BYTES = 24 * 1024;
const PACKAGE_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const SEMVER = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Accept",
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8"
    }
  });
}

function isSingleLine(value) {
  return typeof value === "string" && !/[\r\n\0]/.test(value);
}

function validateSubmission(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Request body must be a JSON object.");
  }

  const { name, version, description, arch, source, recipe_body: recipeBody } = input;
  const dependencies = input.dependencies ?? "";

  if (typeof name !== "string" || !PACKAGE_NAME.test(name)) {
    throw new Error("Package name must be lowercase letters or numbers separated by single hyphens.");
  }
  if (typeof version !== "string" || !SEMVER.test(version)) {
    throw new Error("Version must use semantic version format, such as 1.0.0.");
  }
  if (!isSingleLine(description) || !description.trim() || description.length > 240) {
    throw new Error("Description is required and must be 240 characters or fewer on one line.");
  }
  if (!["x86_64", "aarch64"].includes(arch)) {
    throw new Error("Architecture must be x86_64 or aarch64.");
  }
  if (typeof dependencies !== "string" || dependencies.length > 500 || /[\r\n\0]/.test(dependencies)) {
    throw new Error("Dependencies must be a comma-separated string of package names.");
  }
  const dependencyNames = dependencies.split(",").map(value => value.trim()).filter(Boolean);
  if (dependencyNames.some(value => !PACKAGE_NAME.test(value))) {
    throw new Error("Dependencies must be lowercase package names separated by commas.");
  }
  if (typeof source !== "string" || source.length > 500) {
    throw new Error("Source must be a public HTTPS Git URL.");
  }
  let sourceUrl;
  try {
    sourceUrl = new URL(source);
  } catch {
    throw new Error("Source must be a public HTTPS Git URL.");
  }
  if (sourceUrl.protocol !== "https:" || !sourceUrl.hostname || sourceUrl.username || sourceUrl.password) {
    throw new Error("Source must be a public HTTPS Git URL without embedded credentials.");
  }
  if (typeof recipeBody !== "string" || !recipeBody.trim()) {
    throw new Error("Recipe functions are required.");
  }
  if (new TextEncoder().encode(recipeBody).byteLength > MAX_RECIPE_BYTES || recipeBody.includes("\0")) {
    throw new Error("Recipe functions must be 24,000 bytes or fewer.");
  }
  if (!/(^|\n)\s*build\s*\(\)\s*\{/.test(recipeBody) ||
      !/(^|\n)\s*package\s*\(\)\s*\{/.test(recipeBody)) {
    throw new Error("Recipe must define both build() and package() functions.");
  }

  return {
    name,
    version,
    description: description.trim(),
    arch,
    dependencies: dependencyNames.join(", "),
    source: sourceUrl.href,
    recipeBody: recipeBody.trim()
  };
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Accept",
          "Access-Control-Max-Age": "86400"
        }
      });
    }
    if (request.method !== "POST") {
      return jsonResponse({ success: false, error: "Method not allowed." }, 405);
    }
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("content-type") || "")) {
      return jsonResponse({ success: false, error: "Content-Type must be application/json." }, 415);
    }

    const declaredLength = Number(request.headers.get("content-length") || 0);
    if (declaredLength > MAX_REQUEST_BYTES) {
      return jsonResponse({ success: false, error: "Submission is too large." }, 413);
    }

    let body;
    try {
      body = await request.text();
    } catch {
      return jsonResponse({ success: false, error: "Could not read the request body." }, 400);
    }
    if (new TextEncoder().encode(body).byteLength > MAX_REQUEST_BYTES) {
      return jsonResponse({ success: false, error: "Submission is too large." }, 413);
    }

    let input;
    try {
      input = JSON.parse(body);
    } catch {
      return jsonResponse({ success: false, error: "Request body must contain valid JSON." }, 400);
    }

    let submission;
    if (!env.KATPKGS) {
      console.error("R2 binding KATPKGS is not configured.");
      return jsonResponse({ success: false, error: "Package queue is not configured." }, 500);
    }

    try {
      submission = validateSubmission(input);
    } catch (error) {
      return jsonResponse({ success: false, error: error.message }, 400);
    }

    const recipe = [
      `name=${submission.name}`,
      `version=${submission.version}`,
      `description=${submission.description}`,
      `arch=${submission.arch}`,
      `dependencies=${submission.dependencies}`,
      `source=${submission.source}`,
      "",
      submission.recipeBody,
      ""
    ].join("\n");

    try {
      await env.KATPKGS.put(`queue/${submission.name}.recipe`, recipe, {
        httpMetadata: { contentType: "text/plain; charset=utf-8" }
      });
    } catch (error) {
      console.error("Could not queue package recipe in R2.", error);
      return jsonResponse({ success: false, error: "Could not queue the package. Please try again later." }, 502);
    }

    return jsonResponse({ success: true, name: submission.name, queued: true }, 202);
  }
};
