/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The cloud highlight cutter shells out to ffmpeg-static's binary; keep the package out of the
  // bundle and ship the binary with that one function.
  serverExternalPackages: ["ffmpeg-static"],
  // No site may frame the app: a framed, signed-in page would expose click-only actions (delete
  // game, remove access, sign out) to clickjacking. X-Frame-Options covers older browsers.
  headers: () => [{
    source: "/:path*",
    headers: [
      { key: "Content-Security-Policy", value: "frame-ancestors 'none'" },
      { key: "X-Frame-Options", value: "DENY" },
    ],
  }],
  outputFileTracingIncludes: { "/api/highlights": ["./node_modules/ffmpeg-static/ffmpeg"], "/api/highlights/upload": ["./node_modules/ffmpeg-static/ffmpeg"] },
};
export default nextConfig;
