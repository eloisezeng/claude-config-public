---
name: search-the-production-record-before-buying-a-measurement
description: before paying for a measurement a task specifies, query the production record for it and check the specified instrument can even see the deciding variable
metadata:
  type: feedback
scope: global
---
When a task hands you an instrument ("launch a throwaway machine and run X"), do two things before you pay for it. First, query the PRODUCTION record for the same measurement: a failure, a fallback or a retry often ran the exact path you were told to build a rig for, on the real machine, under real contention. Second, ask what variable actually decides the question the measurement is for, and whether the specified instrument can see it. An instrument can be both redundant and blind at once, and neither flaw is visible from the task's wording.

**Why:** measured 2026-10-28. A handoff told me to launch a throwaway Fly machine and run one serial `.com` zone ingest, to decide whether to retire a 11,595-line parallel path. The production run-metrics table already held that run: a burst machine had died the previous day, the serial fallback had done the whole job on the production box, and the row recorded 43.9 minutes, 562 MB peak RSS and 410 run files — better evidence than an idle rig, because the real box carries the worker, Next, the lander and the router beside it. The rig was also blind to the deciding variable: all 28 historical failures of the serial path were DOWNLOAD failures, and a throwaway machine's download throughput says nothing about the production machine's, so the run would have spent one of ICANN's one-per-24-hours zone transfers and still left the question open. Running it would have cost a transfer on a lane just restored from a 15-day outage, for no new information.

