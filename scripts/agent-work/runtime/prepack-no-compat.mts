import { preparePrepackArtifacts, resolvePrepackBuildEnvironment } from "./scripts/openclaw-prepack.ts";
await preparePrepackArtifacts(resolvePrepackBuildEnvironment());
