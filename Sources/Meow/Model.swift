@_exported import MongoKitten

/// Something that can represent itself as a String (key)
public protocol KeyRepresentable : Hashable {
    
    /// The BSON key string for the key
    var keyString: String { get }
    
}

/// Used to define all keys in a Model.
///
/// This is normally implemented by an enum in the code that is generated by Meow.
/// You normally do not need to implement this protocol yourself.
public protocol ModelKey : KeyRepresentable {
    
    /// The type of the variable that this key represents in the model
    var type: Any.Type { get }
    
    /// An array containing all keys belonging to the model
    static var all: [Self] { get }
    
}

/// Used to define partial values for a model.
///
/// This is normally implemented by a struct in the code that is generated by Meow.
/// You normally do not need to implement this protocol yourself.
///
/// The value structs can be used for default or partial values, or updates
public protocol ModelValues : SerializableToDocument {
    
    /// Initialize a new, empty value struct.
    init()
    
}

extension String : KeyRepresentable {
    public var keyString: String {
        return self
    }
}

/// Makes an ObjectId able to represent a Key
extension ObjectId : KeyRepresentable {
    public var keyString: String {
        return hexString
    }
}

/// `BaseModel` is the base protocol that every model conforms to.
///
/// Models are not expected to conform directly to `BaseModel`. They state conformance to `Model`, which inherits from
/// `BaseModel`. The actual implementation of the protocol is usually handled in an extension generated by Sourcery/Meow.
///
/// The reason `Model` is split up into `Model` and `BaseModel`, is that `Model` has associated type requirements.
/// This currently makes it impossible to use `Model` as a concrete type, e.g. function argument or array type, without
/// making the function generic.
///
/// When possible, model methods are added to the `BaseModel` protocol, and not the `Model` protocol. 
public protocol BaseModel : SerializableToDocument, Convertible {
    /// The collection this entity resides in
    static var collection: MongoKitten.Collection { get }
    
    /// Will be called before saving the Model. Throwing from here will prevent the model from saving.
    /// Note that, if the model has not been changed, the update may not actually get pushed to the database.
    func willSave() throws
    
    /// Will be called when the Model has been saved.
    ///
    /// - parameter wasUpdated: If the save operation actually updated the database
    func didSave(wasUpdated: Bool) throws
    
    /// The database identifier. You do **NOT** need to add this yourself. It will be implemented for you using Sourcery.
    var _id: ObjectId { get set }
    
    /// Will be called when the Model will be deleted. Throwing from here will prevent the model from being deleted.
    func willDelete() throws
    
    /// Will be called when the Model is deleted. At this point, it is no longer in the database and saves will no longer work because the ObjectId is invalidated.
    func didDelete() throws
    
    /// Instantiates this BaseModel from a primitive
    init(newFrom source: BSON.Primitive) throws
    
    /// Validates an update document
    static func validateUpdate(with document: Document) throws
    
    /// Updates a model with a Document, overriding its own properties with those from the document
    func update(with document: Document) throws
}

/// When implemented, indicated that this is a model that resides at the lowest level of a collection, as a separate entity.
///
/// Embeddables will have a generated Virtual variant of itself for the type safe queries
public protocol Model : class, BaseModel, Hashable {
    associatedtype Key : ModelKey = String
    associatedtype VirtualInstance : VirtualModelInstance
    associatedtype Values : ModelValues
    typealias QueryBuilder = (VirtualInstance) throws -> (Query)
}

extension Model {
    /// Makes the model hashable, thus unique, thus usable in a Dictionary
    public var hashValue: Int {
        return _id.hashValue
    }
    
    /// Make a type-safe query for this model
    ///
    /// For more information about type safe queries, see the guide and the documentation on the types whose name start with `Virtual`.
    public static func makeQuery(_ closure: QueryBuilder) rethrows -> Query {
        return try closure(VirtualInstance(keyPrefix: ""))
    }
    
    /// Remove all instances matching the query.
    ///
    /// For more information about type safe queries, see the guide and the documentation on the types whose name start with `Virtual`.
    public static func remove(limitedTo limit: Int? = nil, _ query: QueryBuilder) throws {
        try self.remove(makeQuery(query), limitedTo: limit)
    }
    
    
    /// Performs a find operation using a type-safe query.
    ///
    /// For more information about type safe queries, see the guide and the documentation on the types whose name start with `Virtual`.
    public static func find(sortedBy sort: Sort? = nil, skipping skip: Int? = nil, limitedTo limit: Int? = nil, withBatchSize batchSize: Int = 100, _ query: QueryBuilder) throws -> CollectionSlice<Self> {
        return try find(makeQuery(query), sortedBy: sort, skipping: skip, limitedTo: limit, withBatchSize: batchSize)
    }
    
    /// Performs a findOne operation using a type-safe query.
    ///
    /// For more information about type safe queries, see the guide and the documentation on the types whose name start with `Virtual`.
    public static func findOne(_ query: QueryBuilder) throws -> Self? {
        return try findOne(makeQuery(query))
    }
}

extension BaseModel {
    /// Provides `Equatable` conformance. Just calls `===` because two instances pointing to the same model cannot exist.
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs._id == rhs._id
    }
}

public extension BaseModel {
    /// Will be called before saving the Model. Throwing from here will prevent the model from saving.
    public func willSave() throws {}
    
    /// Will be called when the Model has been saved to the database.
    public func didSave(wasUpdated: Bool) throws {}
    
    /// Will be called when the Model will be deleted. Throwing from here will prevent the model from being deleted.
    public func willDelete() throws {}
    
    /// Will be called when the Model is deleted. At this point, it is no longer in the database and saves will no longer work because the ObjectId is invalidated.
    public func didDelete() throws {}
}


/// Implementes basic CRUD functionality for the object
extension BaseModel {
    /// Converts BaseModel to another KittenCore Type using lossy conversion
    public func convert<DT>(to type: DT.Type) -> DT.SupportedValue? where DT : DataType {
        return self.serialize().convert(to: type)
    }
    
    /// Counts the amount of objects matching the query
    public static func count(_ filter: Query? = nil, limiting limit: Int? = nil, skipping skip: Int? = nil) throws -> Int {
        return try collection.count(filter, limiting: limit, skipping: skip)
    }
    
    /// Removes this object from the database
    ///
    /// Before deleting, `willDelete()` is called. `willDelete()` can throw to prevent the deletion.
    /// When the deletion is complete, `didDelete()` is called.
    public func delete() throws {
        try self.willDelete()
        Meow.pool.invalidate(self._id)
        try Self.collection.remove("_id" == self._id)
        try self.didDelete()
    }
    
    /// Returns the first object matching the query
    public static func findOne(_ query: Query? = nil) throws -> Self? {
        // We don't reuse find here because that one does not have proper error reporting
        guard let document = try collection.findOne(query) else {
            return nil
        }
        
        return try Self.instantiateIfNeeded(document)
    }
    
    /// Saves this object to the database
    ///
    /// - parameter force: Defaults to `false`. If set to true, the object is saved even if it has not been changed.
    public func save(force: Bool = false) throws {
        try self.willSave()
        
        let document = self.serialize()
        Meow.pool.pool(self)
        
        let hash = document.meowHash
        
        guard force || hash != Meow.pool.existingHash(for: self) else {
            print("🐈 Not saving \(self) because it is unchanged")
            try self.didSave(wasUpdated: false)
            return
        }
        
        print("🐈 Saving \(self)")
        
        try Self.collection.update("_id" == self._id,
                                   to: document,
                                   upserting: true
        )
        
        Meow.pool.updateHash(for: self, with: hash)
        
        try self.didSave(wasUpdated: true)
    }
    
    /// Removes all entities matching the query
    /// Errors that happen during deletion will be collected and a `Meow.error.deletingMultiple` will be thrown if errors occurred
    ///
    /// - parameter query: The query to apply to the remove operation
    /// - parameter limit: The maximum number of objects to remove
    public static func remove(_ query: Query? = nil, limitedTo limit: Int? = nil) throws {
        var errors = [(ObjectId, Error)]()
        for instance in try self.find(query, limitedTo: limit) {
            do {
                try instance.delete()
            } catch {
                errors.append((instance._id, error))
            }
        }
        
        guard errors.count == 0 else {
            throw Meow.Error.deletingMultiple(errors: errors)
        }
    }
    
    /// Returns all objects matching the query
    public static func find(_ query: Query? = nil, sortedBy sort: Sort? = nil, skipping skip: Int? = nil, limitedTo limit: Int? = nil, withBatchSize batchSize: Int = 100) throws -> CollectionSlice<Self> {
        return try collection.find(query, sortedBy: sort, skipping: skip, limitedTo: limit, withBatchSize: batchSize).flatMap { document in
            do {
                return try Self.instantiateIfNeeded(document)
            } catch {
                print("🐈 Initializing from document failed: \(error)")
                assertionFailure()
                return nil
            }
        }
    }
    
    /// Intantiates this instance if needed, or pulls the existing entity from memory when able
    public static func instantiateIfNeeded(_ document: Document) throws -> Self {
        return try Meow.pool.instantiateIfNeeded(type: Self.self, document: document)
    }
}
