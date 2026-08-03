//
//  LumeDTOs.swift
//  WorkspaceManagerCore
//
//  Wire models shared by LumeWorkspaceProvider (HTTP daemon path) and
//  LumeRuntimeService (base-VM provisioning path) — both talk to the same
//  Lume HTTP API and previously carried field-identical duplicate structs.
//

import Foundation

struct LumePullImageRequest: Encodable {
    let image: String
    let name: String
    let registry: String
    let organization: String
    let storage: String?
}

struct LumeStorageBody: Encodable {
    let storage: String
}

struct LumePullImageResponse: Decodable {
    let message: String
    let image: String
    let name: String
}

struct LumeMessageResponse: Decodable {
    let message: String
}

struct LumeEmptyBody: Encodable {}
struct LumeEmptyResponse: LumeHTTPEmptyResponse {}
