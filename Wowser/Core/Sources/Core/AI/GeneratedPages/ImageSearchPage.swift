import Ink
import Foundation
import ChatToys

private struct ImageSearchPageModel {
    var query: String
    var page: Int = 0
    var imageResults: [ImageSearchResult]?
    
    func html() -> String {
        let imageItems: [String] = (imageResults ?? []).map { item in
            let hostDisplay = item.hostPageURL.hostWithoutWWW ?? item.hostPageURL.host ?? item.hostPageURL.absoluteString
            return """
            <div class="imageResult">
                <a href="\(item.imageURL.absoluteString)" class="imageLink">
                    <img class="thumbnail" src="\(item.thumbnailURL?.absoluteString ?? item.imageURL.absoluteString)" alt="" />
                    <img class="fullImage" src="\(item.imageURL.absoluteString)" alt="" />
                </a>
                <a href="\(item.hostPageURL.absoluteString)" class="sourceLink">
                    \(hostDisplay)
                </a>
            </div>
            """
        }
        
        // Pagination links
        let paginationHTML: String = {
            var links: [String] = []
            
            if page > 0 {
                let prevKey = GeneratedPageKey.imageSearch(q: query, page: page - 1)
                links.append("<a href=\"\(prevKey.url.absoluteString)\">← Previous</a>")
            }
            
            let nextKey = GeneratedPageKey.imageSearch(q: query, page: page + 1)
            links.append("<a href=\"\(nextKey.url.absoluteString)\">Next →</a>")
            
            return links.isEmpty ? "" : "<div class='pagination'>\(links.joined(separator: " | "))</div>"
        }()
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset='utf-8' />
        <meta name='viewport' content='width=device-width, initial-scale=1' />
        <title>Images: \(query.escapedForHTML)</title>
        <style>
            :root {
                --background-light: #fff;
                --text-light: #0500200;
                --text-secondary-light: rgba(31, 14, 8, 0.66);
                --border-light: #e0e0e0;
                
                --background-dark: #1c1c1e;
                --text-dark: #e5e5e7;
                --text-secondary-dark: rgba(229, 229, 231, 0.66);
                --border-dark: #3a3a3c;
            }
            
            @media (prefers-color-scheme: light) {
                body {
                    background-color: var(--background-light);
                    color: var(--text-light);
                }
                .imageResult {
                    border: 1px solid var(--border-light);
                }
                .sourceLink {
                    color: var(--text-secondary-light);
                }
            }
            
            @media (prefers-color-scheme: dark) {
                body {
                    background-color: var(--background-dark);
                    color: var(--text-dark);
                }
                .imageResult {
                    border: 1px solid var(--border-dark);
                }
                .sourceLink {
                    color: var(--text-secondary-dark);
                }
            }
            
            body { 
                font-family: -apple-system, BlinkMacSystemFont, sans-serif; 
                line-height: 1.5;
                max-width: 1200px; 
                margin: 0 auto; 
                padding: 40px; 
                box-sizing: border-box;
            }
            
            @media screen and (max-width: 500px) {
                body {
                    padding: 24px;
                }
            }
            
            h1 {
                margin-bottom: 2em;
                font-size: 1.5em;
            }
            
            .imageGrid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
                gap: 1.5em;
                margin-bottom: 2em;
            }
            
            .imageResult {
                border-radius: 8px;
                overflow: hidden;
                padding: 0.5em;
            }
            
            .imageLink {
                display: block;
                margin-bottom: 0.5em;
                position: relative;
            }
            
            .imageResult img {
                width: 100%;
                height: 150px;
                object-fit: cover;
                border-radius: 4px;
            }
            
            .imageResult .thumbnail {
                display: block;
            }
            
            .imageResult .fullImage {
                position: absolute;
                top: 0;
                left: 0;
            }
            
            .imageResult .fullImage:loaded,
            .imageResult .fullImage.loaded {
                opacity: 1;
            }
            
            .sourceLink {
                font-size: small;
                text-decoration: none;
                display: block;
                text-overflow: ellipsis;
                overflow: hidden;
                white-space: nowrap;
            }
            
            .sourceLink:hover {
                text-decoration: underline;
            }
            
            a {
                color: inherit;
                text-decoration: inherit;
            }
            
            .pagination {
                font-size: small;
            }
            
            .pagination a {
                color: inherit;
                text-decoration: underline;
                margin-right: 1em;
            }
        </style>
        </head>
        <body>
            <div class="imageGrid">
                \(imageItems.joined(separator: "\n"))
            </div>
            \(paginationHTML)
        </body>
        </html>
        """
        return html
    }
}

extension PageGenerator {
    static func generateImageSearch(query: String, page: Int = 0, continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
        var model = ImageSearchPageModel(query: query, page: page)
        
        async let imageResults_ = try await GoogleImageSearchEngine().searchImages(query: query, page: page)
        
        model.imageResults = try await imageResults_
        continuation.yield(ContentUpdate(html: model.html(), progress: 1))
        continuation.finish()
    }
}
