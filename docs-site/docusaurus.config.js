// @ts-check

const siteUrl = process.env.DOCUSAURUS_SITE_URL || "https://docs.fastpaca.com";
const baseUrl = process.env.DOCUSAURUS_BASE_URL || "/";

const config = {
  title: "Fastpaca Context Store Docs",
  tagline: "Self-host Fastpaca Context Store with confidence",
  url: siteUrl,
  baseUrl,
  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",
  favicon: "https://docusaurus.io/favicon.ico",
  organizationName: "fastpaca",
  projectName: "context-store",
  trailingSlash: false,
  i18n: {
    defaultLocale: "en",
    locales: ["en"]
  },
  markdown: {
    mermaid: true,
  },
  themeConfig: {
    announcementBar: {
      id: "wip-banner",
      content:
        "<strong>Early access:</strong> Fastpaca Context Store is an active work in progress. Expect rapid changes and review carefully before running in production.",
      backgroundColor: "#f97316",
      textColor: "#1f2937",
      isCloseable: false
    }
  },
  themes: ["@docusaurus/theme-mermaid"],
  presets: [
    [
      "@docusaurus/preset-classic",
      {
        docs: {
          path: "../docs",
          routeBasePath: "/",
          sidebarPath: require.resolve("./sidebars.js"),
          editUrl: "https://github.com/fastpaca/context-store/tree/main/docs/"
        },
        blog: false,
        theme: {
          customCss: require.resolve("./src/css/custom.css")
        }
      }
    ]
  ]
};

module.exports = config;
