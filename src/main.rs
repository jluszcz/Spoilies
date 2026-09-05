//! Spike A probe. Deleted in Task 2, Step 9 — see
//! `docs/superpowers/spikes/2026-08-16-sqlx-offline-musl-arm.md`.

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Referenced so the connector is linked rather than merely resolved: a
    // dependency that is never called can be dropped before the linker sees it,
    // which would make this spike pass for the wrong reason.
    let opts = aurora_dsql_sqlx_connector::DsqlConnectOptions::from_connection_string(
        "postgres://admin@example.dsql.us-east-2.on.aws/postgres",
    )?;
    println!("connector parsed options: {opts:?}");

    let url = std::env::var("DATABASE_URL")?;
    let pool = sqlx::PgPool::connect(&url).await?;

    // The macro under test: checked against the schema at compile time.
    let row = sqlx::query!("SELECT name FROM spike WHERE id = $1", 1_i32)
        .fetch_one(&pool)
        .await?;
    println!("spike row: {}", row.name);

    Ok(())
}
