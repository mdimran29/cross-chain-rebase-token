import path from "path";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // @coinbase/cdp-sdk (pulled in transitively by RainbowKit's Coinbase/Base
  // connector) lazily imports these x402 payment packages as optional peer
  // deps that this app never installs or uses. Exclude them from server
  // bundling so webpack doesn't try to statically resolve the dynamic import.
  serverExternalPackages: ["@coinbase/cdp-sdk"],
  turbopack: {
    root: path.join(__dirname),
  },
};

export default nextConfig;
