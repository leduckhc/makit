/**
 * Pure helpers for pino-mirror that can be unit-tested without a real pi process.
 */

export interface HostOpenFields {
  kind: "host.open";
  title: string;
  cwd: string;
  spawnToken?: string;
}

export interface BuildHostOpenOpts {
  title: string;
  cwd: string;
  spawnToken?: string;
}

/** Build the fields for the host.open command frame. */
export function buildHostOpenFields(opts: BuildHostOpenOpts): HostOpenFields {
  const fields: HostOpenFields = { kind: "host.open", title: opts.title, cwd: opts.cwd };
  if (opts.spawnToken) fields.spawnToken = opts.spawnToken;
  return fields;
}
