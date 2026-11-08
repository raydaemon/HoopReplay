/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The cloud highlight cutter shells out to ffmpeg-static's binary; keep the package out of the
  // bundle and ship the binary with that one function.
  serverExternalPackages: ["ffmpeg-static"],
  outputFileTracingIncludes: { "/api/highlights": ["./node_modules/ffmpeg-static/ffmpeg"], "/api/highlights/upload": ["./node_modules/ffmpeg-static/ffmpeg"] },
};
export default nextConfig;
