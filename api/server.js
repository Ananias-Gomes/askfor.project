// Rota para salvar a nota do aluno no banco de dados
app.post('/api/resultados', async (req, res) => {
  const { alunoId, avaliacaoId, nota, observacao } = req.body;
  
  try {
    await sql.connect(dbConfig);
    // Insere os dados diretamente na tabela
    await sql.query`
      INSERT INTO dbo.Resultados (AlunoId, AvaliacaoId, Nota, Observacao) 
      VALUES (${alunoId}, ${avaliacaoId}, ${nota}, ${observacao})
    `;
    res.status(201).json({ mensagem: 'Resultado salvo com sucesso' });
  } catch (err) {
    res.status(500).send({ erro: err.message });
  }
});