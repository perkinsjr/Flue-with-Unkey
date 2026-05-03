import type { FlueContext } from '@flue/sdk/client';
import * as v from 'valibot';

export const triggers = { webhook: true };

export default async function ({ init, payload }: FlueContext) {
  const agent = await init({ model: 'anthropic/claude-sonnet-4-6' });
  const session = await agent.session();

  return await session.prompt(
    `Analyze the following metrics and surface the most important insights:\n\n${payload.metrics}`,
    {
      role: 'analyst',
      result: v.object({
        headline: v.string(),
        insights: v.array(
          v.object({
            metric: v.string(),
            takeaway: v.string(),
            severity: v.picklist(['info', 'warning', 'critical']),
          }),
        ),
      }),
    },
  );
}
