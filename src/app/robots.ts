import { MetadataRoute } from 'next'

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: '*',
        allow: '/',
        disallow: ['/teamqtech', '/s-quxf5u4k84'],
      },
    ],
    sitemap: 'https://www.qbnettech.com/sitemap.xml',
    host: 'https://www.qbnettech.com',
  }
}
