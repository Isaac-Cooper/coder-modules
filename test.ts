import { readableStreamToText, spawn } from "bun";
import { afterEach, expect, it } from "bun:test";
import { readFile, unlink } from "fs/promises";

export const runContainer = async (
  image: string,
  init = "sleep infinity",
): Promise<string> => {
  const proc = spawn([
    "docker",
    "run",
    "--rm",
    "-d",
    "--label",
    "modules-test=true",
    "--network",
    "host",
    "--entrypoint",
    "sh",
    image,
    "-c",
    init,
  ]);
  let containerID = await readableStreamToText(proc.stdout);
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(containerID);
  }
  return containerID.trim();
};

/**
 * Finds the only "coder_script" resource in the given state and runs it in a
 * container.
 */
export const executeScriptInContainer = async (
  state: TerraformState,
  image: string,
  shell: string = "sh",
): Promise<{
  exitCode: number;
  stdout: string[];
  stderr: string[];
}> => {
  const instance = findResourceInstance(state, "coder_script");
  const id = await runContainer(image);
  const resp = await execContainer(id, [shell, "-c", instance.script]);
  const stdout = resp.stdout.trim().split("\n");
  const stderr = resp.stderr.trim().split("\n");
  return {
    exitCode: resp.exitCode,
    stdout,
    stderr,
  };
};

export const execContainer = async (
  id: string,
  cmd: string[],
): Promise<{
  exitCode: number;
  stderr: string;
  stdout: string;
}> => {
  const proc = spawn(["docker", "exec", id, ...cmd], {
    stderr: "pipe",
    stdout: "pipe",
  });
  const [stderr, stdout] = await Promise.all([
    readableStreamToText(proc.stderr),
    readableStreamToText(proc.stdout),
  ]);
  const exitCode = await proc.exited;
  return {
    exitCode,
    stderr,
    stdout,
  };
};

type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

type TerraformStateResource = {
  type: string;
  name: string;
  provider: string;
  instances: [{ attributes: Record<string, any> }];
};

export interface TerraformState {
  outputs: {
    [key: string]: {
      type: string;
      value: any;
    };
  };

  resources: [TerraformStateResource, ...TerraformStateResource[]];
}

export interface CoderScriptAttributes {
  script: string;
  agent_id: string;
  url: string;
}

/**
 * finds the first instance of the given resource type in the given state. If
 * name is specified, it will only find the instance with the given name.
 */
export const findResourceInstance = <T extends string>(
  state: TerraformState,
  type: T,
  name?: string,
  // if type is "coder_script" return CoderScriptAttributes
): T extends "coder_script"
  ? CoderScriptAttributes
  : Record<string, string> => {
  const resource = state.resources.find(
    (resource) =>
      resource.type === type && (name ? resource.name === name : true),
  );
  if (!resource) {
    throw new Error(`Resource ${type} not found`);
  }
  if (resource.instances.length !== 1) {
    throw new Error(
      `Resource ${type} has ${resource.instances.length} instances`,
    );
  }
  return resource.instances[0].attributes as any;
};

/**
 * Creates a test-case for each variable provided and ensures that the apply
 * fails without it.
 */
export const testRequiredVariables = <TVars extends Record<string, string>>(
  dir: string,
  vars: TVars,
) => {
  // Ensures that all required variables are provided.
  it("required variables", async () => {
    await runTerraformApply(dir, vars);
  });

  const varNames = Object.keys(vars);
  varNames.forEach((varName) => {
    // Ensures that every variable provided is required!
    it("missing variable " + varName, async () => {
      const localVars: Record<string, string> = {};
      varNames.forEach((otherVarName) => {
        if (otherVarName !== varName) {
          localVars[otherVarName] = vars[otherVarName];
        }
      });

      try {
        await runTerraformApply(dir, localVars);
      } catch (ex) {
        if (!(ex instanceof Error)) {
          throw new Error("Unknown error generated");
        }

        expect(ex.message).toContain(
          `input variable \"${varName}\" is not set`,
        );
        return;
      }
      throw new Error(`${varName} is not a required variable!`);
    });
  });
};

/**
 * Runs terraform apply in the given directory with the given variables. It is
 * fine to run in parallel with other instances of this function, as it uses a
 * random state file.
 */
export const runTerraformApply = async <
  TVars extends Readonly<Record<string, string | boolean>>,
>(
  dir: string,
  vars: TVars,
  env?: Record<string, string>,
): Promise<TerraformState> => {
  const stateFile = `${dir}/${crypto.randomUUID()}.tfstate`;

  const combinedEnv = env === undefined ? {} : { ...env };
  for (const [key, value] of Object.entries(vars)) {
    combinedEnv[`TF_VAR_${key}`] = String(value);
  }

  const proc = spawn(
    [
      "terraform",
      "apply",
      "-compact-warnings",
      "-input=false",
      "-auto-approve",
      "-state",
      "-no-color",
      stateFile,
    ],
    {
      cwd: dir,
      env: combinedEnv,
      stderr: "pipe",
      stdout: "pipe",
    },
  );

  const text = await readableStreamToText(proc.stderr);
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(text);
  }

  const content = await readFile(stateFile, "utf8");
  await unlink(stateFile);
  return JSON.parse(content);
};

/**
 * Runs terraform init in the given directory.
 */
export const runTerraformInit = async (dir: string) => {
  const proc = spawn(["terraform", "init"], {
    cwd: dir,
  });
  const text = await readableStreamToText(proc.stdout);
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(text);
  }
};

export const createJSONResponse = (obj: object, statusCode = 200): Response => {
  return new Response(JSON.stringify(obj), {
    headers: {
      "Content-Type": "application/json",
    },
    status: statusCode,
  });
};

export const writeCoder = async (id: string, script: string) => {
  const exec = await execContainer(id, [
    "sh",
    "-c",
    `echo '${script}' > /usr/bin/coder && chmod +x /usr/bin/coder`,
  ]);
  expect(exec.exitCode).toBe(0);
};
