// @ts-check

const siteUrl = process.env.DOCUSAURUS_SITE_URL || "https://docs.example.com";
const baseUrl = process.env.DOCUSAURUS_BASE_URL || "/";

const config = {
  title: "FleetLM Docs",
  tagline: "Self-host FleetLM with confidence",
  url: siteUrl,
  baseUrl,
  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",
  favicon: "https://docusaurus.io/favicon.ico",
  organizationName: "cpluss",
  projectName: "fleetlm",
  trailingSlash: false,
  i18n: {
    defaultLocale: "en",
    locales: ["en"]
  },
  presets: [
    [
      "@docusaurus/preset-classic",
      {
        docs: {
          path: "../docs",
          routeBasePath: "/",
          sidebarPath: require.resolve("./sidebars.js"),
          editUrl: "https://github.com/cpluss/fleetlm/tree/main/docs/"
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
