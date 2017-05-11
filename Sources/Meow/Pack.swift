import BSON
import MongoKitten

fileprivate func _unpack<S : Serializable>(_ key: String, from primitive: Primitive?) throws -> S {
    if let M = S.self as? BaseModel.Type {
        guard let document = primitive as? Document, let ref = DBRef(document, inDatabase: Meow.database) else {
            throw Meow.Error.missingOrInvalidValue(key: key)
        }
        
        guard let instance = try M.findOne("_id" == ref.id) else {
            throw Meow.Error.brokenReference(in: [ref])
        }
        
        return instance as! S
    } else {
        guard let primitive = primitive else {
            throw Meow.Error.missingValue(key: key)
        }
        
        return try S(restoring: primitive)
    }
}

fileprivate func _pack(_ serializable: Serializable?) -> Primitive? {
    if let serializable = serializable as? BaseModel {
        return DBRef(referencing: serializable._id, inCollection: type(of: serializable).collection)
    } else {
        return serializable?.serialize()
    }
}

extension Document {
    public func unpack<S : Serializable>(_ key: String) throws -> S {
        return try _unpack(key, from: self[key])
    }
    
    public mutating func pack(_ serializable: Serializable?, as key: String) {
        self[key] = _pack(serializable)
    }
}

extension Document {
    public func unpack<S : Serializable>(_ key: String) throws -> [S] {
        guard let array = self[key] as? Document, array.validatesAsArray() else {
            throw Meow.Error.missingOrInvalidValue(key: key)
        }
        
        return try array.arrayValue.map { try _unpack(key, from: $0) }
    }
    
    public func unpack<S : Serializable>(_ key: String) throws -> Set<S> {
        return try Set(unpack(key) as [S])
    }
    
    public mutating func pack<S : Sequence>(_ serializables: S?, as key: String) where S.Iterator.Element : Serializable {
        self[key] = serializables?.map { _pack($0) }
    }
    
    public mutating func pack<V: Serializable>(_ serializable: Dictionary<String, V>, as key: String) {
        let primitives: Document = serializable.map { key, value in
            return [key, value.serialize()]
            }.reduce([], +)
        
        self[key] = primitives
    }
    
    public func unpack<V: Serializable>(_ key: String) throws -> Dictionary<String, V> {
        let doc = try self.unpack(key) as Document
        var dict = [String: V]()
        
        for key in doc.keys {
            dict[key] = try doc.unpack(key)
        }
        
        return dict
    }
    
    public func unpack<K: Hashable & Serializable, V: Serializable>(_ key: String) throws -> Dictionary<K, V> {
        let doc = try self.unpack(key) as Document
        
        var dict = [K: V]()
        
        let keys = try doc.unpack("keys") as [K]
        let values = try doc.unpack("values") as [V]
        
        guard keys.count == values.count else {
            throw Meow.Error.missingOrInvalidValue(key: key)
        }
        
        for i in 0..<keys.count {
            dict[keys[i]] = values[i]
        }
        
        return dict
    }
    
    public mutating func pack<K: Hashable & Serializable, V: Serializable>(_ serializable: Dictionary<K, V>, as key: String) {
        self[key] = [
            "keys": serializable.keys.map { $0.serialize() },
            "values": serializable.values.map { $0.serialize() }
        ]
    }
}
