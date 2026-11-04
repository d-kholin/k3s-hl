import { DatabaseSync, backup } from 'node:sqlite';
import { createReadStream } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';

// SQLite's online backup API produces a consistent database including WAL data.
const directory = await mkdtemp(join(tmpdir(), 'vv-backup-'));
const database = new DatabaseSync(process.env.DB_PATH, { readOnly: true });
try {
  const target = join(directory, 'app.sqlite');
  await backup(database, target);
  await pipeline(createReadStream(target), process.stdout);
} finally {
  database.close();
  await rm(directory, { recursive: true, force: true });
}
