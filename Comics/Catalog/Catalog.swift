import Foundation

/// The bundled list of comics and the recipes used to index and read them.
struct Catalog: Codable, Equatable {
    static let supportedSchema = 1

    let schema: Int
    let version: Int
    let comics: [ComicDef]
}

struct ComicDef: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let author: String
    let home: URL
    let about: String
    let shape: Shape
    let index: IndexRecipe
    let strip: StripRecipe

    enum Shape: String, Codable {
        case portrait, wide, mixed
    }
}

private enum KindKey: String, CodingKey {
    case kind
}

/// How to discover a comic's strips. Encoded as a flat object with a `kind` discriminator.
enum IndexRecipe: Codable, Equatable {
    case numbered(Numbered)
    case wordpress(WordPress)
    case linkList(LinkList)

    struct Numbered: Codable, Equatable {
        let latestURL: URL
        /// Regex with a named capture `n`.
        let latestPattern: String
        let first: Int
        let skip: [Int]
    }

    struct WordPress: Codable, Equatable {
        /// `.../wp-json/wp/v2/<type>`
        let api: URL
    }

    struct LinkList: Codable, Equatable {
        let url: URL
        /// Regex with named captures `key`, and optionally `title` and `date`.
        let itemPattern: String
        /// `{key}` is substituted.
        let pageTemplate: String
        let newestFirst: Bool
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: KindKey.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "numbered": self = .numbered(try Numbered(from: decoder))
        case "wordpress": self = .wordpress(try WordPress(from: decoder))
        case "linkList": self = .linkList(try LinkList(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown index kind '\(kind)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KindKey.self)
        switch self {
        case .numbered(let v):
            try c.encode("numbered", forKey: .kind)
            try v.encode(to: encoder)
        case .wordpress(let v):
            try c.encode("wordpress", forKey: .kind)
            try v.encode(to: encoder)
        case .linkList(let v):
            try c.encode("linkList", forKey: .kind)
            try v.encode(to: encoder)
        }
    }
}

/// How to read one strip's page. Encoded as a flat object with a `kind` discriminator.
enum StripRecipe: Codable, Equatable {
    case json(JSONStrip)
    case html(HTMLStrip)

    struct JSONStrip: Codable, Equatable {
        /// Templates with `{key}`.
        let url: String
        let page: String
        /// JSON field names.
        let image: String
        let title: String?
        let hover: String?
    }

    struct HTMLStrip: Codable, Equatable {
        /// Template with `{key}` or `{page}`.
        let url: String
        /// Each pattern captures `v`.
        let imagePattern: String
        let titlePattern: String?
        let hoverPattern: String?
        let bonusPattern: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: KindKey.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "json": self = .json(try JSONStrip(from: decoder))
        case "html": self = .html(try HTMLStrip(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown strip kind '\(kind)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KindKey.self)
        switch self {
        case .json(let v):
            try c.encode("json", forKey: .kind)
            try v.encode(to: encoder)
        case .html(let v):
            try c.encode("html", forKey: .kind)
            try v.encode(to: encoder)
        }
    }
}
