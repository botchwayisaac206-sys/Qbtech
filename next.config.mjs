/** @type {import('next').NextConfig} */
const nextConfig = {
  webpack: (config) => {
    config.resolve.symlinks = false
    config.cache = false
    config.snapshot = {
      managedPaths: [],
      immutablePaths: [],
    }
    return config
  },
  // The Dahua portal moved to /teamhikview. Staff bookmarks and any link
  // still pointing at the old path keep working.
  async redirects() {
    return [
      { source: '/dahua-stock', destination: '/teamhikview', permanent: true },
    ]
  },
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: 'yzriyjqnzouefuqdrqek.supabase.co',
        port: '',
        pathname: '/storage/v1/object/public/**',
      },
    ],
  },
}

export default nextConfig
